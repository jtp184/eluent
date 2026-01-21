# frozen_string_literal: true

FactoryBot.define do
  sequence(:atom_id) { |n| "testrepo-01JBZTMQ1R#{format('%016d', n).tr('0-9', 'ABCDEFGHJK')}" }

  factory :atom, class: 'Eluent::Models::Atom' do
    id { generate(:atom_id) }
    title { Faker::Lorem.sentence(word_count: 4) }
    description { Faker::Lorem.paragraph }
    status { :open }
    issue_type { :task }
    priority { 2 }
    labels { [] }
    assignee { nil }
    parent_id { nil }
    defer_until { nil }
    close_reason { nil }
    created_at { Time.now.utc }
    updated_at { Time.now.utc }
    metadata { {} }

    initialize_with do
      new(**attributes)
    end

    # Status traits
    trait :open do
      status { :open }
    end

    trait :in_progress do
      status { :in_progress }
    end

    trait :blocked do
      status { :blocked }
    end

    trait :deferred do
      status { :deferred }
      defer_until { Time.now.utc + 86_400 } # 1 day from now
    end

    trait :review do
      status { :review }
    end

    trait :testing do
      status { :testing }
    end

    trait :closed do
      status { :closed }
      close_reason { 'completed' }
    end

    trait :discarded do
      status { :discard }
      close_reason { 'wont_do' }
    end

    trait :wont_do do
      status { :wont_do }
      close_reason { 'wont_do' }
    end

    # Issue type traits
    trait :feature do
      issue_type { :feature }
      title { "Feature: #{Faker::Lorem.sentence(word_count: 3)}" }
    end

    trait :bug do
      issue_type { :bug }
      title { "Bug: #{Faker::Lorem.sentence(word_count: 3)}" }
    end

    trait :task do
      issue_type { :task }
    end

    trait :artifact do
      issue_type { :artifact }
    end

    trait :discovery do
      issue_type { :discovery }
      title { "Discovery: #{Faker::Lorem.sentence(word_count: 3)}" }
    end

    trait :epic do
      issue_type { :epic }
    end

    trait :formula do
      issue_type { :formula }
    end

    # Priority traits
    trait :high_priority do
      priority { 1 }
    end

    trait :low_priority do
      priority { 3 }
    end

    # Relationship traits
    trait :with_parent do
      transient do
        parent { nil }
      end

      parent_id { parent&.id || generate(:atom_id) }
    end

    trait :with_labels do
      labels { %w[urgent backend] }
    end

    trait :with_assignee do
      assignee { Faker::Internet.username }
    end

    trait :with_metadata do
      metadata { { source: 'import', original_id: '123' } }
    end

    # Deferral traits
    trait :defer_past do
      status { :deferred }
      defer_until { Time.now.utc - 86_400 } # 1 day ago
    end

    trait :defer_future do
      status { :deferred }
      defer_until { Time.now.utc + 86_400 } # 1 day from now
    end
  end
end
