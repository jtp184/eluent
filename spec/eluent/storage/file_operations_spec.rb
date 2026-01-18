# frozen_string_literal: true

require 'tempfile'
require 'fileutils'

RSpec.describe Eluent::Storage::FileOperations do
  let(:temp_dir) { Dir.mktmpdir }
  let(:test_path) { File.join(temp_dir, 'data.jsonl') }

  after { FileUtils.remove_entry(temp_dir) if Dir.exist?(temp_dir) }

  describe '.append_record' do
    it 'creates the file if it does not exist' do
      described_class.append_record(test_path, { key: 'value' })
      expect(File.exist?(test_path)).to be true
    end

    it 'appends a JSON line to the file' do
      described_class.append_record(test_path, { key: 'value1' })
      described_class.append_record(test_path, { key: 'value2' })

      lines = File.readlines(test_path)
      expect(lines.length).to eq(2)
    end

    it 'serializes hashes to JSON' do
      described_class.append_record(test_path, { key: 'value' })
      content = File.read(test_path).strip
      expect(JSON.parse(content)).to eq({ 'key' => 'value' })
    end

    it 'handles string records directly' do
      json_string = '{"pre":"serialized"}'
      described_class.append_record(test_path, json_string)
      expect(File.read(test_path).strip).to eq(json_string)
    end
  end

  describe '.read_all_records' do
    it 'returns empty array for non-existent file' do
      expect(described_class.read_all_records('/nonexistent_file_path')).to eq([])
    end

    it 'returns empty array for empty file' do
      FileUtils.touch(test_path)
      expect(described_class.read_all_records(test_path)).to eq([])
    end

    it 'parses all JSON lines' do
      File.write(test_path, "{\"key\":\"value1\"}\n{\"key\":\"value2\"}\n")
      records = described_class.read_all_records(test_path)

      expect(records).to eq([{ key: 'value1' }, { key: 'value2' }])
    end

    it 'skips malformed lines' do
      File.write(test_path, "{\"valid\":true}\ninvalid json\n{\"also\":\"valid\"}\n")
      records = described_class.read_all_records(test_path)

      expect(records).to eq([{ valid: true }, { also: 'valid' }])
    end

    it 'skips empty lines' do
      File.write(test_path, "{\"key\":\"value\"}\n\n{\"other\":\"data\"}\n")
      records = described_class.read_all_records(test_path)

      expect(records.length).to eq(2)
    end
  end

  describe '.each_record' do
    before do
      File.write(test_path, "{\"n\":1}\n{\"n\":2}\n{\"n\":3}\n")
    end

    it 'yields each parsed record' do
      records = []
      described_class.each_record(test_path) { |r| records << r }
      expect(records).to eq([{ n: 1 }, { n: 2 }, { n: 3 }])
    end

    it 'returns an enumerator without a block' do
      enum = described_class.each_record(test_path)
      expect(enum).to be_an(Enumerator)
      expect(enum.to_a).to eq([{ n: 1 }, { n: 2 }, { n: 3 }])
    end
  end

  describe '.find_record' do
    before do
      File.write(test_path, "{\"id\":\"a\"}\n{\"id\":\"b\"}\n{\"id\":\"c\"}\n")
    end

    it 'returns the first matching record' do
      record = described_class.find_record(test_path) { |r| r[:id] == 'b' }
      expect(record).to eq({ id: 'b' })
    end

    it 'returns nil if no match' do
      record = described_class.find_record(test_path) { |r| r[:id] == 'z' }
      expect(record).to be_nil
    end
  end

  describe '.record_exists?' do
    before do
      File.write(test_path, "{\"id\":\"a\"}\n{\"id\":\"b\"}\n")
    end

    it 'returns true if a matching record exists' do
      exists = described_class.record_exists?(test_path) { |r| r[:id] == 'a' }
      expect(exists).to be true
    end

    it 'returns false if no matching record exists' do
      exists = described_class.record_exists?(test_path) { |r| r[:id] == 'z' }
      expect(exists).to be false
    end
  end

  describe '.rewrite_file' do
    before do
      File.write(test_path, "{\"n\":1}\n{\"n\":2}\n{\"n\":3}\n")
    end

    it 'transforms records through the block' do
      described_class.rewrite_file(test_path) do |records|
        records.map { |r| { n: r[:n] * 10 } }
      end

      records = described_class.read_all_records(test_path)
      expect(records).to eq([{ n: 10 }, { n: 20 }, { n: 30 }])
    end

    it 'allows filtering records' do
      described_class.rewrite_file(test_path) do |records|
        records.reject { |r| r[:n] == 2 }
      end

      records = described_class.read_all_records(test_path)
      expect(records).to eq([{ n: 1 }, { n: 3 }])
    end

    it 'does nothing if file does not exist' do
      non_existent = File.join(temp_dir, 'nonexistent.jsonl')
      described_class.rewrite_file(non_existent) { |r| r }
      expect(File.exist?(non_existent)).to be false
    end
  end

  describe '.write_records_atomically' do
    it 'writes all records to the file' do
      records = [{ a: 1 }, { b: 2 }]
      described_class.write_records_atomically(test_path, records)

      expect(described_class.read_all_records(test_path)).to eq(records)
    end

    it 'overwrites existing content' do
      File.write(test_path, "{\"old\":true}\n")
      described_class.write_records_atomically(test_path, [{ new: true }])

      records = described_class.read_all_records(test_path)
      expect(records).to eq([{ new: true }])
    end

    it 'cleans up temp file on success' do
      described_class.write_records_atomically(test_path, [{ a: 1 }])
      expect(File.exist?("#{test_path}.tmp")).to be false
    end
  end

  describe '.serialize_record' do
    it 'returns strings unchanged' do
      expect(described_class.serialize_record('{"json":"string"}')).to eq('{"json":"string"}')
    end

    it 'converts hashes to JSON' do
      result = described_class.serialize_record({ key: 'value' })
      expect(JSON.parse(result)).to eq({ 'key' => 'value' })
    end

    it 'calls to_json on other objects' do
      obj = double(to_json: '{"custom":"json"}')
      expect(described_class.serialize_record(obj)).to eq('{"custom":"json"}')
    end
  end

  describe '.parse_line' do
    it 'returns nil for empty strings' do
      expect(described_class.parse_line('')).to be_nil
    end

    it 'parses valid JSON with symbolized keys' do
      result = described_class.parse_line('{"key":"value"}')
      expect(result).to eq({ key: 'value' })
    end

    it 'returns nil for invalid JSON' do
      expect(described_class.parse_line('not json')).to be_nil
    end
  end
end
