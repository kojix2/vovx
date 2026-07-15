require "../spec_helper"

private def write_u16(io : IO, value : UInt16) : Nil
  bytes = uninitialized UInt8[2]
  IO::ByteFormat::LittleEndian.encode(value, bytes.to_slice)
  io.write(bytes.to_slice)
end

private def write_u32(io : IO, value : UInt32) : Nil
  bytes = uninitialized UInt8[4]
  IO::ByteFormat::LittleEndian.encode(value, bytes.to_slice)
  io.write(bytes.to_slice)
end

private def read_u32(bytes : Bytes, offset : Int32) : UInt32
  IO::ByteFormat::LittleEndian.decode(UInt32, bytes[offset, 4])
end

private def test_wav(data : Bytes, sample_rate = 24_000_u32) : Bytes
  channels = 1_u16
  bits_per_sample = 16_u16
  block_align = (channels * bits_per_sample // 8).to_u16
  byte_rate = sample_rate * block_align
  riff_size = 36_u32 + data.size.to_u32

  io = IO::Memory.new
  io.write("RIFF".to_slice)
  write_u32(io, riff_size)
  io.write("WAVE".to_slice)
  io.write("fmt ".to_slice)
  write_u32(io, 16_u32)
  write_u16(io, 1_u16)
  write_u16(io, channels)
  write_u32(io, sample_rate)
  write_u32(io, byte_rate)
  write_u16(io, block_align)
  write_u16(io, bits_per_sample)
  io.write("data".to_slice)
  write_u32(io, data.size.to_u32)
  io.write(data)
  io.to_slice
end

private def with_temp_path(&)
  file = File.tempfile("vovx_wav_", ".wav")
  path = file.path
  file.close
  yield path
ensure
  File.delete?(path) if path
end

describe VOVX::WavWriter do
  it "concatenates WAV data and patches canonical header sizes" do
    with_temp_path do |path|
      writer = VOVX::WavWriter.new(path)
      writer.append_bytes(test_wav(UInt8.slice(1, 2, 3, 4)))
      writer.append_bytes(test_wav(UInt8.slice(5, 6)))
      writer.close

      output = File.read(path).to_slice
      output[0, 4].should eq("RIFF".to_slice)
      output[8, 4].should eq("WAVE".to_slice)
      read_u32(output, 4).should eq(42_u32)
      read_u32(output, 40).should eq(6_u32)
      output[44, 6].to_a.should eq([1_u8, 2_u8, 3_u8, 4_u8, 5_u8, 6_u8])
    end
  end

  it "rejects mismatched input formats" do
    with_temp_path do |path|
      writer = VOVX::WavWriter.new(path)
      writer.append_bytes(test_wav(UInt8.slice(1, 2), sample_rate: 24_000_u32))

      expect_raises(Exception, "WAV format mismatch") do
        writer.append_bytes(test_wav(UInt8.slice(3, 4), sample_rate: 48_000_u32))
      end
    ensure
      writer.try &.close
    end
  end

  it "parses WAV files with non-audio chunks before data" do
    base = test_wav(UInt8.slice(9, 8, 7, 6))
    io = IO::Memory.new
    io.write(base[0, 12])
    io.write("JUNK".to_slice)
    write_u32(io, 2_u32)
    io.write(UInt8.slice(0xaa, 0xbb))
    io.write(base[12, base.size - 12])
    wav = VOVX::WavWriter.parse(io.to_slice)

    wav.data_size.should eq(4)
    wav.format.sample_rate.should eq(24_000_u32)
  end

  it "raises when closed without audio data" do
    with_temp_path do |path|
      writer = VOVX::WavWriter.new(path)

      expect_raises(Exception, "no WAV data was written") do
        writer.close
      end
    end
  end
end
