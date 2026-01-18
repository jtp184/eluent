# frozen_string_literal: true

RSpec.describe Eluent::Models::Atom do
  let(:atom) { build(:atom, id: test_atom_id) }
  let(:same_identity_entity) { build(:atom, id: test_atom_id) }
  let(:different_identity_entity) { build(:atom, id: test_atom_id('ZYXWVTSRQPNMKJHG')) }
  let(:entity) { atom }
  let(:expected_type) { 'atom' }
  let(:expected_keys) do
    %i[_type id title description status issue_type priority labels
       assignee parent_id defer_until close_reason created_at updated_at metadata]
  end
  let(:timestamp_keys) { %i[created_at updated_at defer_until] }

  it_behaves_like 'an entity with identity'
  it_behaves_like 'a serializable entity'

  describe '#initialize' do
    it 'requires id and title' do
      atom = described_class.new(id: 'test-id', title: 'Test Title')
      expect(atom.id).to eq('test-id')
      expect(atom.title).to eq('Test Title')
    end

    it 'sets default values' do
      atom = described_class.new(id: 'test-id', title: 'Test')

      expect(atom.status).to eq(Eluent::Models::Status[:open])
      expect(atom.issue_type).to eq(Eluent::Models::IssueType[:task])
      expect(atom.priority).to eq(2)
      expect(atom.labels).to be_a(Set)
      expect(atom.labels).to be_empty
      expect(atom.metadata).to eq({})
    end

    it 'converts labels to a Set' do
      atom = described_class.new(id: 'test', title: 'Test', labels: %w[a b c])
      expect(atom.labels).to be_a(Set)
      expect(atom.labels).to contain_exactly('a', 'b', 'c')
    end

    it 'validates status' do
      expect { described_class.new(id: 'test', title: 'Test', status: :invalid) }
        .to raise_error(Eluent::Models::ValidationError)
    end

    it 'validates issue_type' do
      expect { described_class.new(id: 'test', title: 'Test', issue_type: :invalid) }
        .to raise_error(Eluent::Models::ValidationError)
    end

    it 'validates priority' do
      expect { described_class.new(id: 'test', title: 'Test', priority: 'high') }
        .to raise_error(Eluent::Models::ValidationError)
    end

    it 'parses defer_until time strings' do
      atom = described_class.new(id: 'test', title: 'Test', defer_until: '2025-06-15T12:00:00Z')
      expect(atom.defer_until).to be_a(Time)
      expect(atom.defer_until).to be_utc
    end
  end

  describe 'status predicate methods' do
    Eluent::Models::Status.all.each_key do |status_name|
      describe "##{status_name}?" do
        it "returns true when status is #{status_name}" do
          atom = build(:atom, status: status_name)
          expect(atom.public_send("#{status_name}?")).to be true
        end

        it "returns false when status is not #{status_name}" do
          other_status = (Eluent::Models::Status.all.keys - [status_name]).first
          atom = build(:atom, status: other_status)
          expect(atom.public_send("#{status_name}?")).to be false
        end
      end
    end
  end

  describe 'issue type predicate methods' do
    Eluent::Models::IssueType.all.each_key do |type_name|
      describe "##{type_name}?" do
        it "returns true when issue_type is #{type_name}" do
          atom = build(:atom, issue_type: type_name)
          expect(atom.public_send("#{type_name}?")).to be true
        end

        it "returns false when issue_type is not #{type_name}" do
          other_type = (Eluent::Models::IssueType.all.keys - [type_name]).first
          atom = build(:atom, issue_type: other_type)
          expect(atom.public_send("#{type_name}?")).to be false
        end
      end
    end
  end

  describe '#abstract?' do
    it 'delegates to issue_type' do
      epic = build(:atom, :epic)
      task = build(:atom, :task)

      expect(epic).to be_abstract
      expect(task).not_to be_abstract
    end
  end

  describe '#root?' do
    it 'returns true when parent_id is nil' do
      atom = build(:atom, parent_id: nil)
      expect(atom).to be_root
    end

    it 'returns false when parent_id is set' do
      atom = build(:atom, :with_parent)
      expect(atom).not_to be_root
    end
  end

  describe '#child?' do
    it 'returns false when parent_id is nil' do
      atom = build(:atom, parent_id: nil)
      expect(atom).not_to be_child
    end

    it 'returns true when parent_id is set' do
      atom = build(:atom, :with_parent)
      expect(atom).to be_child
    end
  end

  describe '#defer_past?' do
    it 'returns nil when defer_until is nil' do
      atom = build(:atom, defer_until: nil)
      expect(atom.defer_past?).to be_nil
    end

    it 'returns true when defer_until is in the past' do
      Timecop.freeze(Time.utc(2025, 6, 15, 12, 0, 0)) do
        atom = build(:atom, defer_until: Time.utc(2025, 6, 14, 12, 0, 0))
        expect(atom.defer_past?).to be true
      end
    end

    it 'returns false when defer_until is in the future' do
      Timecop.freeze(Time.utc(2025, 6, 15, 12, 0, 0)) do
        atom = build(:atom, defer_until: Time.utc(2025, 6, 16, 12, 0, 0))
        expect(atom.defer_past?).to be false
      end
    end
  end

  describe '#defer_future?' do
    it 'returns false when status is not deferred' do
      atom = build(:atom, status: :open, defer_until: Time.now.utc + 3600)
      expect(atom.defer_future?).to be false
    end

    it 'returns falsey when defer_until is nil' do
      atom = build(:atom, status: :deferred, defer_until: nil)
      expect(atom.defer_future?).to be_falsey
    end

    it 'returns false when defer_until is in the past' do
      Timecop.freeze(Time.utc(2025, 6, 15, 12, 0, 0)) do
        atom = build(:atom, status: :deferred, defer_until: Time.utc(2025, 6, 14, 12, 0, 0))
        expect(atom.defer_future?).to be false
      end
    end

    it 'returns true when deferred and defer_until is in the future' do
      Timecop.freeze(Time.utc(2025, 6, 15, 12, 0, 0)) do
        atom = build(:atom, status: :deferred, defer_until: Time.utc(2025, 6, 16, 12, 0, 0))
        expect(atom.defer_future?).to be true
      end
    end
  end

  describe '#to_h' do
    subject(:hash) { atom.to_h }

    it 'includes the atom type marker' do
      expect(hash[:_type]).to eq('atom')
    end

    it 'converts status to string' do
      expect(hash[:status]).to eq(atom.status.to_s)
    end

    it 'converts issue_type to string' do
      expect(hash[:issue_type]).to eq(atom.issue_type.to_s)
    end

    it 'converts labels Set to array' do
      atom = build(:atom, :with_labels)
      expect(atom.to_h[:labels]).to be_an(Array)
    end

    it 'formats timestamps as ISO8601' do
      expect(hash[:created_at]).to match(/\A\d{4}-\d{2}-\d{2}T/)
    end
  end

  describe 'factory traits' do
    it 'creates blocked atoms' do
      atom = build(:atom, :blocked)
      expect(atom).to be_blocked
    end

    it 'creates closed atoms with close_reason' do
      atom = build(:atom, :closed)
      expect(atom).to be_closed
      expect(atom.close_reason).not_to be_nil
    end

    it 'creates feature atoms' do
      atom = build(:atom, :feature)
      expect(atom).to be_feature
    end

    it 'creates bug atoms' do
      atom = build(:atom, :bug)
      expect(atom).to be_bug
    end

    it 'creates atoms with labels' do
      atom = build(:atom, :with_labels)
      expect(atom.labels).not_to be_empty
    end

    it 'creates atoms with assignee' do
      atom = build(:atom, :with_assignee)
      expect(atom.assignee).not_to be_nil
    end
  end
end
