# frozen_string_literal: true

RSpec.describe Eluent::Lifecycle::ReadinessCalculator do
  subject(:calculator) { described_class.new(indexer: indexer, blocking_resolver: blocking_resolver) }

  let(:indexer) { Eluent::Storage::Indexer.new }
  let(:graph) { Eluent::Graph::DependencyGraph.new(indexer) }
  let(:blocking_resolver) { Eluent::Graph::BlockingResolver.new(indexer: indexer, dependency_graph: graph) }

  let(:ready_atom) { build(:atom, :open, priority: 2, created_at: Time.now.utc - 3600) }
  let(:high_priority_atom) { build(:atom, :open, priority: 1, created_at: Time.now.utc - 1800) }
  let(:old_atom) { build(:atom, :open, priority: 3, created_at: Time.now.utc - (86_400 * 3)) }

  before do
    [ready_atom, high_priority_atom, old_atom].each { |atom| indexer.index_atom(atom) }
  end

  describe 'SORT_POLICIES' do
    it 'includes expected policies' do
      expect(described_class::SORT_POLICIES).to contain_exactly(:priority, :oldest, :hybrid)
    end
  end

  describe '#ready_items' do
    context 'with no filters' do
      it 'returns all ready items' do
        items = calculator.ready_items
        expect(items.map(&:id)).to contain_exactly(ready_atom.id, high_priority_atom.id, old_atom.id)
      end
    end

    context 'excluding closed items' do
      let(:closed_atom) { build(:atom, :closed) }

      before { indexer.index_atom(closed_atom) }

      it 'does not include closed items' do
        items = calculator.ready_items
        expect(items.map(&:id)).not_to include(closed_atom.id)
      end
    end

    context 'excluding discarded items' do
      let(:discarded_atom) { build(:atom, :discarded) }

      before { indexer.index_atom(discarded_atom) }

      it 'does not include discarded items' do
        items = calculator.ready_items
        expect(items.map(&:id)).not_to include(discarded_atom.id)
      end
    end

    context 'excluding abstract items by default' do
      let(:epic_atom) { build(:atom, :epic) }

      before { indexer.index_atom(epic_atom) }

      it 'does not include abstract items' do
        items = calculator.ready_items
        expect(items.map(&:id)).not_to include(epic_atom.id)
      end

      it 'includes abstract items when include_abstract is true' do
        items = calculator.ready_items(include_abstract: true)
        expect(items.map(&:id)).to include(epic_atom.id)
      end
    end

    context 'excluding blocked items' do
      let(:blocker) { build(:atom, :open) }
      let(:blocked) { build(:atom, :open) }

      before do
        indexer.index_atom(blocker)
        indexer.index_atom(blocked)
        indexer.index_bond(build(:bond, source_id: blocker.id, target_id: blocked.id))
      end

      it 'does not include blocked items' do
        items = calculator.ready_items
        expect(items.map(&:id)).not_to include(blocked.id)
      end
    end

    context 'excluding future deferred items' do
      let(:deferred_atom) { build(:atom, :defer_future) }

      before { indexer.index_atom(deferred_atom) }

      it 'does not include items deferred to future' do
        items = calculator.ready_items
        expect(items.map(&:id)).not_to include(deferred_atom.id)
      end
    end

    context 'including past deferred items' do
      let(:deferred_past_atom) { build(:atom, :defer_past) }

      before { indexer.index_atom(deferred_past_atom) }

      it 'includes items whose defer_until has passed' do
        items = calculator.ready_items
        expect(items.map(&:id)).to include(deferred_past_atom.id)
      end
    end

    context 'with type filter' do
      let(:bug_atom) { build(:atom, :bug) }
      let(:feature_atom) { build(:atom, :feature) }

      before do
        indexer.index_atom(bug_atom)
        indexer.index_atom(feature_atom)
      end

      it 'filters by issue type' do
        items = calculator.ready_items(type: :bug)
        expect(items.map(&:id)).to eq([bug_atom.id])
      end
    end

    context 'with exclude_types filter' do
      let(:task_atom) { build(:atom, :task) }
      let(:bug_atom) { build(:atom, :bug) }

      before do
        indexer.index_atom(task_atom)
        indexer.index_atom(bug_atom)
      end

      it 'excludes specified types' do
        items = calculator.ready_items(exclude_types: %i[task])
        expect(items.map(&:id)).not_to include(task_atom.id)
        expect(items.map(&:id)).to include(bug_atom.id)
      end
    end

    context 'with assignee filter' do
      let(:assigned_atom) { build(:atom, :with_assignee, assignee: 'user@example.com') }

      before { indexer.index_atom(assigned_atom) }

      it 'filters by assignee' do
        items = calculator.ready_items(assignee: 'user@example.com')
        expect(items.map(&:id)).to eq([assigned_atom.id])
      end
    end

    context 'with labels filter' do
      let(:labeled_atom) { build(:atom, :with_labels, labels: %w[urgent backend]) }

      before { indexer.index_atom(labeled_atom) }

      it 'filters by labels (all must match)' do
        items = calculator.ready_items(labels: ['urgent'])
        expect(items.map(&:id)).to include(labeled_atom.id)
      end

      it 'requires all labels to match' do
        items = calculator.ready_items(labels: %w[urgent frontend])
        expect(items.map(&:id)).not_to include(labeled_atom.id)
      end
    end

    context 'with priority filter' do
      let(:p1_atom) { build(:atom, priority: 1) }
      let(:p2_atom) { build(:atom, priority: 2) }

      before do
        indexer.index_atom(p1_atom)
        indexer.index_atom(p2_atom)
      end

      it 'filters by exact priority' do
        items = calculator.ready_items(priority: 1)
        expect(items.map(&:id)).to include(p1_atom.id)
        expect(items.none? { |i| i.priority != 1 }).to be true
      end
    end

    context 'with sort policy :priority' do
      it 'sorts by priority (lowest number first), then by creation date' do
        items = calculator.ready_items(sort: :priority)
        priorities = items.map(&:priority)
        expect(priorities).to eq(priorities.sort)
      end
    end

    context 'with sort policy :oldest' do
      it 'sorts by creation date ascending' do
        items = calculator.ready_items(sort: :oldest)
        dates = items.map(&:created_at)
        expect(dates).to eq(dates.sort)
      end
    end

    context 'with sort policy :hybrid' do
      let(:very_old_atom) { build(:atom, :open, priority: 5, created_at: Time.now.utc - (86_400 * 5)) }
      let(:recent_high_priority) { build(:atom, :open, priority: 0, created_at: Time.now.utc - 3600) }

      before do
        indexer.index_atom(very_old_atom)
        indexer.index_atom(recent_high_priority)
      end

      it 'puts older items (>48h) before recent items' do
        items = calculator.ready_items(sort: :hybrid)
        item_ids = items.map(&:id)

        # Very old atom (>48h) should come before recent high priority
        expect(item_ids.index(very_old_atom.id)).to be < item_ids.index(recent_high_priority.id)
      end
    end
  end
end
