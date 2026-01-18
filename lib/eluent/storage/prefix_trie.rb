# frozen_string_literal: true

module Eluent
  module Storage
    # Prefix trie for efficient ID prefix matching
    # Used for short ID lookups against the randomness portion of ULIDs
    class PrefixTrie
      MINIMUM_PREFIX_LENGTH = 4

      def initialize
        self.root = TrieNode.new
        self.count = 0
      end

      attr_reader :count

      def insert(key, value)
        traverse_or_create(normalize(key)).tap do |node|
          next if node.include?(value)

          node.add(value)
          self.count = count + 1
        end
      end

      def delete(key, value)
        find_node(normalize(key))&.delete(value).tap do |deleted|
          self.count = count - 1 unless deleted.nil?
        end
      end

      def prefix_match(prefix)
        find_node(normalize(prefix))&.collect_all_values || []
      end

      def prefix_exists?(prefix)
        !find_node(normalize(prefix)).nil?
      end

      def exact_match(key)
        find_node(normalize(key))&.values_dup || []
      end

      def minimum_unique_prefix(key)
        normalized = normalize(key)
        return nil unless normalized.length >= MINIMUM_PREFIX_LENGTH

        (MINIMUM_PREFIX_LENGTH..normalized.length).each do |len|
          prefix = normalized[0, len]
          return prefix if prefix_match(prefix).length == 1
        end

        normalized
      end

      def clear
        self.root = TrieNode.new
        self.count = 0
      end

      def empty?
        count.zero?
      end

      private

      attr_accessor :root
      attr_writer :count

      def normalize(key) = key.to_s.upcase

      def find_node(key)
        key.each_char.reduce(root) do |node, char|
          node&.child(char)
        end
      end

      def traverse_or_create(key)
        key.each_char.reduce(root) do |node, char|
          node.child_or_create(char)
        end
      end

      # Internal trie node with encapsulated state
      class TrieNode
        def initialize
          self.children = {}
          self.values = []
        end

        def child(char) = children[char]

        def child_or_create(char)
          children[char] ||= TrieNode.new
        end

        def include?(value) = values.include?(value)

        def add(value)
          values << value
        end

        def delete(value)
          values.delete(value)
        end

        def values_dup = values.dup

        def collect_all_values
          values.dup.tap do |result|
            children.each_value { |child| result.concat(child.collect_all_values) }
          end
        end

        private

        attr_accessor :children, :values
      end
    end
  end
end
