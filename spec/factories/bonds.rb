# frozen_string_literal: true

FactoryBot.define do
  factory :bond, class: 'Eluent::Models::Bond' do
    sequence(:source_id) { |n| "testrepo-01JBZTMQ1R#{format('%016d', n).tr('0-9', 'ABCDEFGHJK')}" }
    sequence(:target_id) { |n| "testrepo-01JBZTMQ1R#{format('%016d', n + 1000).tr('0-9', 'ABCDEFGHJK')}" }
    dependency_type { :blocks }
    created_at { Time.now.utc }
    metadata { {} }

    initialize_with do
      new(**attributes)
    end

    # Dependency type traits - blocking
    trait :blocks do
      dependency_type { :blocks }
    end

    trait :parent_child do
      dependency_type { :parent_child }
    end

    trait :conditional_blocks do
      dependency_type { :conditional_blocks }
    end

    trait :waits_for do
      dependency_type { :waits_for }
    end

    # Dependency type traits - non-blocking
    trait :related do
      dependency_type { :related }
    end

    trait :duplicates do
      dependency_type { :duplicates }
    end

    trait :discovered_from do
      dependency_type { :discovered_from }
    end

    trait :replies_to do
      dependency_type { :replies_to }
    end

    # Convenience traits
    trait :blocking do
      dependency_type { :blocks }
    end

    trait :non_blocking do
      dependency_type { :related }
    end

    trait :with_metadata do
      metadata { { reason: 'technical dependency', created_by: 'test' } }
    end

    # Build a bond between specific atoms
    trait :between do
      transient do
        source { nil }
        target { nil }
      end

      source_id { source&.id || generate(:atom_id) }
      target_id { target&.id || generate(:atom_id) }
    end
  end
end
