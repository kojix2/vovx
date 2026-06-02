require "../spec_helper"

describe VOVX do
  describe ".split_sentences" do
    it "splits Japanese punctuation and trims whitespace" do
      VOVX.split_sentences(" こんにちは。  いい天気ですね！\nはい？ ")
        .should eq(["こんにちは。", "いい天気ですね！", "はい？"])
    end

    it "splits ASCII punctuation" do
      VOVX.split_sentences("Hello! Really? Yes.")
        .should eq(["Hello!", "Really?", "Yes."])
    end

    it "splits on newlines" do
      VOVX.split_sentences("一行目\n二行目\n\n三行目")
        .should eq(["一行目", "二行目", "三行目"])
    end

    it "returns no empty sentences for blank input" do
      VOVX.split_sentences(" \n\t ").should be_empty
    end
  end
end
