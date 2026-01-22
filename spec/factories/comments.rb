# frozen_string_literal: true

FactoryBot.define do
  sequence(:comment_id) { |n| "testrepo-01JBZTMQ1RABCDEFGHKMNPQRST-c#{n}" }

  factory :comment, class: 'Eluent::Models::Comment' do
    id { generate(:comment_id) }
    parent_id { 'testrepo-01JBZTMQ1RABCDEFGHKMNPQRST' }
    author { Faker::Internet.username }
    content { Faker::Lorem.paragraph }
    created_at { Time.now.utc }
    updated_at { Time.now.utc }

    initialize_with do
      new(**attributes)
    end

    # Author traits
    trait :by_bot do
      author { 'claude-bot' }
    end

    trait :by_human do
      author { Faker::Internet.username }
    end

    # Content traits
    trait :short do
      content { Faker::Lorem.sentence }
    end

    trait :long do
      content { Faker::Lorem.paragraphs(number: 5).join("\n\n") }
    end

    trait :with_code do
      content { "Here's the fix:\n\n```ruby\ndef fix\n  true\nend\n```" }
    end

    # Parent relationship
    trait :for_atom do
      transient do
        atom { nil }
      end

      parent_id { atom&.id || 'testrepo-01JBZTMQ1RABCDEFGHKMNPQRST' }
      sequence(:id) { |n| "#{parent_id}-c#{n}" }
    end

    # Timestamp traits
    trait :old do
      created_at { Time.now.utc - (86_400 * 30) } # 30 days ago
      updated_at { Time.now.utc - (86_400 * 30) }
    end

    trait :recent do
      created_at { Time.now.utc - 3600 } # 1 hour ago
      updated_at { Time.now.utc - 3600 }
    end
  end
end
