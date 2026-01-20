# frozen_string_literal: true

module Eluent
  module Agents
    module Concerns
      # Shared HTTP response error handling for API executors
      module HttpErrorHandler
        private

        def handle_response_errors!(response)
          return if response.status.between?(200, 299)

          body = parse_json(response.body.to_s)
          error_message = body.dig('error', 'message')

          case response.status
          when 401
            raise AuthenticationError.new(
              error_message || 'Authentication failed',
              response_body: body
            )
          when 429
            retry_after = response.headers['retry-after']&.to_i
            raise RateLimitError.new(
              error_message || 'Rate limit exceeded',
              retry_after: retry_after,
              response_body: body
            )
          when 400..499
            raise ApiError.new(
              error_message || 'Client error',
              status_code: response.status,
              response_body: body
            )
          when 500..599
            raise ApiError.new(
              error_message || 'Server error',
              status_code: response.status,
              response_body: body
            )
          end
        end
      end
    end
  end
end
