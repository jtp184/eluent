# frozen_string_literal: true

RSpec.describe Eluent::Models::Validations do
  # Create a test class that includes the module
  let(:validator_class) do
    Class.new do
      include Eluent::Models::Validations

      # Expose private methods for testing
      public :validate_title, :validate_content, :validate_status,
             :validate_issue_type, :validate_priority, :validate_utf8,
             :parse_time, :validate_not_self_reference, :validate_dependency_type
    end
  end

  let(:validator) { validator_class.new }

  describe '#validate_title' do
    it 'returns nil for nil input' do
      expect(validator.validate_title(nil)).to be_nil
    end

    it 'converts input to string' do
      expect(validator.validate_title(123)).to eq('123')
    end

    it 'allows titles within the limit' do
      title = 'A' * 500
      expect(validator.validate_title(title)).to eq(title)
    end

    it 'truncates titles exceeding the limit' do
      title = 'A' * 600
      expect(validator.validate_title(title).length).to eq(500)
    end

    it 'outputs a warning when truncating', :aggregate_failures do
      original_verbose = $VERBOSE
      $VERBOSE = true
      expect { validator.validate_title('A' * 600) }
        .to output(/warning: title truncated/).to_stderr
    ensure
      $VERBOSE = original_verbose
    end
  end

  describe '#validate_content' do
    it 'returns nil for nil input' do
      expect(validator.validate_content(nil)).to be_nil
    end

    it 'converts input to string' do
      expect(validator.validate_content(123)).to eq('123')
    end

    it 'allows content within the limit' do
      content = 'A' * 65_536
      expect(validator.validate_content(content)).to eq(content)
    end

    it 'raises ValidationError for content exceeding limit' do
      content = 'A' * 65_537
      expect { validator.validate_content(content) }
        .to raise_error(Eluent::Models::ValidationError, /exceeds 65536 characters/)
    end
  end

  describe '#validate_status' do
    Eluent::Models::Status.all.each_key do |status_name|
      it "accepts valid status: #{status_name}" do
        result = validator.validate_status(status_name)
        expect(result).to eq(Eluent::Models::Status[status_name])
      end

      it "accepts status as string: #{status_name}" do
        result = validator.validate_status(status_name.to_s)
        expect(result).to eq(Eluent::Models::Status[status_name])
      end
    end

    it 'raises ValidationError for invalid status' do
      expect { validator.validate_status(:invalid_status) }
        .to raise_error(Eluent::Models::ValidationError, /invalid status/)
    end
  end

  describe '#validate_issue_type' do
    Eluent::Models::IssueType.all.each_key do |type_name|
      it "accepts valid issue type: #{type_name}" do
        result = validator.validate_issue_type(type_name)
        expect(result).to eq(Eluent::Models::IssueType[type_name])
      end
    end

    it 'raises ValidationError for invalid issue type' do
      expect { validator.validate_issue_type(:invalid_type) }
        .to raise_error(Eluent::Models::ValidationError, /invalid issue_type/)
    end
  end

  describe '#validate_priority' do
    it 'accepts integer values' do
      expect(validator.validate_priority(1)).to eq(1)
      expect(validator.validate_priority(5)).to eq(5)
    end

    it 'converts string numbers to integers' do
      expect(validator.validate_priority('3')).to eq(3)
    end

    it 'raises ValidationError for non-numeric values' do
      expect { validator.validate_priority('high') }
        .to raise_error(Eluent::Models::ValidationError, /must be integer/)
    end
  end

  describe '#validate_utf8' do
    it 'returns valid UTF-8 strings unchanged' do
      text = 'Hello, world!'
      expect(validator.validate_utf8(text)).to eq(text)
    end

    it 'normalizes to NFC form' do
      # e with combining acute accent vs precomposed é
      decomposed = "e\u0301"
      composed = 'é'
      expect(validator.validate_utf8(decomposed)).to eq(composed)
    end

    it 'handles invalid encoding by replacing characters' do
      # Create an invalid UTF-8 string by forcing encoding
      invalid = "hello\xFF\xFEworld".dup.force_encoding('ASCII-8BIT')
      result = validator.validate_utf8(invalid)
      expect(result.valid_encoding?).to be true
      expect(result.encoding).to eq(Encoding::UTF_8)
    end
  end

  describe '#parse_time' do
    it 'returns nil for nil input' do
      expect(validator.parse_time(nil)).to be_nil
    end

    it 'converts Time to UTC' do
      time = Time.now
      result = validator.parse_time(time)
      expect(result).to be_utc
    end

    it 'parses ISO8601 strings' do
      time_str = '2025-06-15T12:00:00Z'
      result = validator.parse_time(time_str)
      expect(result).to eq(Time.utc(2025, 6, 15, 12, 0, 0))
    end

    it 'parses various time string formats' do
      time_str = '2025-06-15 12:00:00'
      result = validator.parse_time(time_str)
      expect(result.year).to eq(2025)
      expect(result.month).to eq(6)
      expect(result.day).to eq(15)
    end

    it 'raises ValidationError for invalid time values' do
      expect { validator.parse_time(123) }
        .to raise_error(Eluent::Models::ValidationError, /invalid time value/)
    end
  end

  describe '#validate_not_self_reference' do
    it 'allows different source and target IDs' do
      expect { validator.validate_not_self_reference(source_id: 'a', target_id: 'b') }
        .not_to raise_error
    end

    it 'allows nil source_id' do
      expect { validator.validate_not_self_reference(source_id: nil, target_id: 'b') }
        .not_to raise_error
    end

    it 'allows nil target_id' do
      expect { validator.validate_not_self_reference(source_id: 'a', target_id: nil) }
        .not_to raise_error
    end

    it 'raises SelfReferenceError when source equals target' do
      expect { validator.validate_not_self_reference(source_id: 'same', target_id: 'same') }
        .to raise_error(Eluent::Models::SelfReferenceError, /cannot depend on itself/)
    end
  end

  describe '#validate_dependency_type' do
    Eluent::Models::DependencyType.all.each_key do |type_name|
      it "accepts valid dependency type: #{type_name}" do
        result = validator.validate_dependency_type(type_name)
        expect(result).to eq(Eluent::Models::DependencyType[type_name])
      end
    end

    it 'raises ValidationError for invalid dependency type' do
      expect { validator.validate_dependency_type(:invalid_dep) }
        .to raise_error(Eluent::Models::ValidationError, /invalid dependency_type/)
    end
  end
end
