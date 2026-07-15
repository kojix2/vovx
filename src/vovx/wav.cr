module VOVX
  struct WavFormat
    getter audio_format : UInt16
    getter channels : UInt16
    getter sample_rate : UInt32
    getter byte_rate : UInt32
    getter block_align : UInt16
    getter bits_per_sample : UInt16

    def initialize(@audio_format : UInt16, @channels : UInt16, @sample_rate : UInt32, @byte_rate : UInt32, @block_align : UInt16, @bits_per_sample : UInt16)
    end
  end

  struct WavData
    getter format : WavFormat
    getter data_offset : Int32
    getter data_size : Int32

    def initialize(@format : WavFormat, @data_offset : Int32, @data_size : Int32)
    end
  end

  class WavWriter
    HEADER_SIZE = 44

    @format : WavFormat? = nil
    @data_size = 0_u32
    @closed = false

    def initialize(path : String)
      @file = File.open(path, "w+")
    end

    def append_file(path : String) : Nil
      append_bytes(File.read(path).to_slice)
    end

    def append_bytes(bytes : Bytes) : Nil
      raise "WAV writer is already closed" if @closed

      wav = self.class.parse(bytes)
      if format = @format
        raise "WAV format mismatch" unless format == wav.format
      else
        @format = wav.format
        write_header(wav.format, 0_u32)
      end

      data_size = wav.data_size.to_u32
      raise "WAV data is too large" if @data_size > UInt32::MAX - data_size

      @file.write(bytes[wav.data_offset, wav.data_size])
      @data_size += data_size
    end

    def close : Nil
      return if @closed

      unless format = @format
        @closed = true
        @file.close
        raise "no WAV data was written"
      end

      begin
        patch_header(format, @data_size)
      ensure
        @closed = true
        @file.close unless @file.closed?
      end
    end

    def self.parse(bytes : Bytes) : WavData
      raise "invalid WAV: too small" if bytes.size < 12
      raise "invalid WAV: missing RIFF header" unless ascii_at?(bytes, 0, "RIFF")
      raise "invalid WAV: missing WAVE header" unless ascii_at?(bytes, 8, "WAVE")

      format = nil
      data_offset = nil
      data_size = nil
      offset = 12

      while offset + 8 <= bytes.size
        chunk = read_chunk(bytes, offset)

        case chunk.id
        when "fmt "
          format = parse_format(bytes, chunk)
        when "data"
          data_offset = chunk.start
          data_size = chunk.size
          break
        end

        offset = chunk.next_offset
      end

      wav_format = format || raise "invalid WAV: missing fmt chunk"
      raise "unsupported WAV: only PCM is supported" unless wav_format.audio_format == 1
      offset = data_offset || raise "invalid WAV: missing data chunk"
      size = data_size || raise "invalid WAV: missing data chunk"
      WavData.new(wav_format, offset, size)
    end

    private record Chunk, id : String, start : Int32, size : Int32 do
      def next_offset : Int32
        chunk_end = start + size
        chunk_end + (size.odd? ? 1 : 0)
      end
    end

    private def self.read_chunk(bytes : Bytes, offset : Int32) : Chunk
      chunk_id = String.new(bytes[offset, 4])
      chunk_size = read_u32(bytes, offset + 4).to_i
      chunk_start = offset + 8
      chunk_end = chunk_start + chunk_size
      raise "invalid WAV: truncated #{chunk_id} chunk" if chunk_end > bytes.size

      Chunk.new(chunk_id, chunk_start, chunk_size)
    end

    private def self.parse_format(bytes : Bytes, chunk : Chunk) : WavFormat
      raise "invalid WAV: fmt chunk is too small" if chunk.size < 16

      WavFormat.new(
        read_u16(bytes, chunk.start),
        read_u16(bytes, chunk.start + 2),
        read_u32(bytes, chunk.start + 4),
        read_u32(bytes, chunk.start + 8),
        read_u16(bytes, chunk.start + 12),
        read_u16(bytes, chunk.start + 14)
      )
    end

    private def write_header(format : WavFormat, data_size : UInt32) : Nil
      @file.rewind
      @file.write "RIFF".to_slice
      write_u32(36_u32 + data_size)
      @file.write "WAVE".to_slice
      @file.write "fmt ".to_slice
      write_u32(16_u32)
      write_u16(format.audio_format)
      write_u16(format.channels)
      write_u32(format.sample_rate)
      write_u32(format.byte_rate)
      write_u16(format.block_align)
      write_u16(format.bits_per_sample)
      @file.write "data".to_slice
      write_u32(data_size)
    end

    private def patch_header(format : WavFormat, data_size : UInt32) : Nil
      write_header(format, data_size)
      @file.flush
    end

    private def write_u16(value : UInt16) : Nil
      bytes = uninitialized UInt8[2]
      IO::ByteFormat::LittleEndian.encode(value, bytes.to_slice)
      @file.write(bytes.to_slice)
    end

    private def write_u32(value : UInt32) : Nil
      bytes = uninitialized UInt8[4]
      IO::ByteFormat::LittleEndian.encode(value, bytes.to_slice)
      @file.write(bytes.to_slice)
    end

    private def self.read_u16(bytes : Bytes, offset : Int32) : UInt16
      IO::ByteFormat::LittleEndian.decode(UInt16, bytes[offset, 2])
    end

    private def self.read_u32(bytes : Bytes, offset : Int32) : UInt32
      IO::ByteFormat::LittleEndian.decode(UInt32, bytes[offset, 4])
    end

    private def self.ascii_at?(bytes : Bytes, offset : Int32, value : String) : Bool
      offset + value.bytesize <= bytes.size && String.new(bytes[offset, value.bytesize]) == value
    end
  end
end
