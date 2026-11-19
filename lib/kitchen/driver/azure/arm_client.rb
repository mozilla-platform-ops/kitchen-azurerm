require "json" unless defined?(JSON)
require "time" unless defined?(Time.httpdate)
require "uri" unless defined?(URI)

require_relative "errors"
require_relative "http"

module Kitchen
  module Driver
    module Azure
      # A minimal Azure Resource Manager client covering exactly the operations
      # this driver performs.
      #
      # Replaces +azure_mgmt_resources2+, +azure_mgmt_network2+, +ms_rest2+ and
      # +ms_rest_azure2+, which are forks of Microsoft's retired Azure SDK for
      # Ruby. Responses are returned as parsed JSON, so callers see ARM's own
      # camelCase property names rather than the SDK's generated model objects.
      class ArmClient
        # ARM API version used for resource group and deployment requests.
        #
        # @return [String]
        RESOURCES_API_VERSION = "2025-04-01".freeze

        # ARM API version used for network resource requests.
        #
        # @return [String]
        NETWORK_API_VERSION = "2025-07-01".freeze

        # ARM API version used for compute resource requests. Matches the
        # version the bundled deployment templates declare for virtual
        # machines.
        #
        # @return [String]
        COMPUTE_API_VERSION = "2025-04-01".freeze

        # ARM API version used to read the subscription itself.
        #
        # @return [String]
        SUBSCRIPTION_API_VERSION = "2022-12-01".freeze

        # ARM throttles with 429 and tells the caller when to come back. The
        # request was not processed, so it is safe to repeat for any method.
        #
        # @return [Array<Integer>]
        THROTTLED_STATUSES = [429].freeze

        # Server-side failures worth another try. These are retried only for
        # requests that are safe to repeat after a partial success.
        #
        # @return [Array<Integer>]
        SERVER_ERROR_STATUSES = [408, 500, 502, 503, 504].freeze

        # Methods that can be repeated after a server-side failure.
        #
        # @return [Array<Symbol>]
        IDEMPOTENT_METHODS = %i{get head delete}.freeze

        # Retries after the first attempt.
        #
        # @return [Integer]
        DEFAULT_MAX_RETRIES = 6

        # First backoff delay, in seconds. Doubles on each retry.
        #
        # @return [Integer]
        BASE_DELAY = 2

        # Upper bound on one backoff delay, in seconds.
        #
        # @return [Integer]
        MAX_DELAY = 60

        # Upper bound on a server-supplied +Retry-After+, in seconds.
        #
        # @return [Integer]
        MAX_RETRY_AFTER = 120

        # @param subscription_id [String]
        # @param environment [Environments::Environment]
        # @param token_provider [TokenProvider]
        # @param logger [#warn, nil] receives one line per retry.
        # @param max_retries [Integer] retries for throttled or failed requests.
        def initialize(subscription_id:, environment:, token_provider:, logger: nil, max_retries: DEFAULT_MAX_RETRIES)
          @subscription_id = subscription_id
          @environment = environment
          @token_provider = token_provider
          @logger = logger
          @max_retries = max_retries
        end

        # @return [Integer]
        attr_reader :max_retries

        # @return [String]
        attr_reader :subscription_id

        # @return [Environments::Environment]
        attr_reader :environment

        # @return [TokenProvider]
        attr_reader :token_provider

        # Reads the subscription itself.
        #
        # Unlike a resource group HEAD - which answers 404 both for a
        # subscription that does not exist and for one that merely has no such
        # group - this distinguishes a reachable subscription from a wrong
        # one, so it is what {Azurerm#doctor} probes with.
        #
        # @return [Hash]
        def subscription
          call(:get, "/subscriptions/#{escape(subscription_id)}",
            api_version: SUBSCRIPTION_API_VERSION).json
        end

        # Whether a resource group exists.
        #
        # @param name [String] resource group name, case-insensitive.
        # @return [Boolean]
        def resource_group_exists?(name)
          response = call(:head, resource_group_path(name), api_version: RESOURCES_API_VERSION, allow: [404])
          response.status != 404
        end

        # Creates or updates a resource group.
        #
        # @param name [String] resource group name.
        # @param location [String] Azure region.
        # @param tags [Hash] resource tags.
        # @return [Hash] the resource group as ARM returned it.
        def create_or_update_resource_group(name, location:, tags: {})
          call(:put, resource_group_path(name),
            api_version: RESOURCES_API_VERSION,
            body: { "location" => location, "tags" => tags || {} }).json
        end

        # Requests deletion of a resource group, returning as soon as ARM
        # accepts the request rather than waiting for it to finish.
        #
        # A group that is already gone counts as deleted: that is the outcome
        # the caller asked for, and ARM answers 404. Treating that as an error
        # wedged +kitchen destroy+ permanently for any instance whose resource
        # group had been removed out of band - deleted in the portal to save
        # money, or never created because +kitchen create+ failed early. Every
        # subsequent destroy failed the same way, so the instance could only be
        # cleared by hand-deleting its state file.
        #
        # @param name [String] resource group name.
        # @return [void]
        def delete_resource_group(name)
          call(:delete, resource_group_path(name), api_version: RESOURCES_API_VERSION, allow: [404])
          nil
        end

        # Submits a deployment, returning once ARM accepts it.
        #
        # @param resource_group [String]
        # @param name [String] deployment name.
        # @param deployment [Hash] the deployment body, as built by the driver.
        # @return [Hash] the deployment as ARM returned it.
        def create_deployment(resource_group, name, deployment)
          call(:put, deployment_path(resource_group, name),
            api_version: RESOURCES_API_VERSION,
            body: deployment).json
        end

        # Reads a deployment.
        #
        # @param resource_group [String]
        # @param name [String] deployment name.
        # @return [Hash]
        def deployment(resource_group, name)
          call(:get, deployment_path(resource_group, name), api_version: RESOURCES_API_VERSION).json
        end

        # Lists every operation belonging to a deployment.
        #
        # @param resource_group [String]
        # @param name [String] deployment name.
        # @return [Array<Hash>]
        def deployment_operations(resource_group, name)
          payload = call(:get, "#{deployment_path(resource_group, name)}/operations",
            api_version: RESOURCES_API_VERSION).json

          payload.is_a?(Hash) ? Array(payload["value"]) : []
        end

        # Reads a virtual machine's instance view, which carries its current
        # power state.
        #
        # @param resource_group [String]
        # @param name [String] virtual machine name.
        # @return [Hash]
        def virtual_machine_instance_view(resource_group, name)
          call(:get, "#{compute_path(resource_group, "virtualMachines", name)}/instanceView",
            api_version: COMPUTE_API_VERSION).json
        end

        # Reads a public IP address resource.
        #
        # @param resource_group [String]
        # @param name [String] public IP resource name.
        # @return [Hash]
        def public_ip(resource_group, name)
          call(:get, network_path(resource_group, "publicIPAddresses", name),
            api_version: NETWORK_API_VERSION).json
        end

        # Reads a network interface resource.
        #
        # @param resource_group [String]
        # @param name [String] network interface name.
        # @return [Hash]
        def network_interface(resource_group, name)
          call(:get, network_path(resource_group, "networkInterfaces", name),
            api_version: NETWORK_API_VERSION).json
        end

        private

        # @param name [String]
        # @return [String]
        def resource_group_path(name)
          "/subscriptions/#{subscription_id}/resourcegroups/#{escape(name)}"
        end

        # @param resource_group [String]
        # @param name [String]
        # @return [String]
        def deployment_path(resource_group, name)
          "#{resource_group_path(resource_group)}/providers/Microsoft.Resources/deployments/#{escape(name)}"
        end

        # @param resource_group [String]
        # @param type [String] e.g. +"publicIPAddresses"+.
        # @param name [String]
        # @return [String]
        def network_path(resource_group, type, name)
          "#{resource_group_path(resource_group)}/providers/Microsoft.Network/#{type}/#{escape(name)}"
        end

        # @param resource_group [String]
        # @param type [String] e.g. +"virtualMachines"+.
        # @param name [String]
        # @return [String]
        def compute_path(resource_group, type, name)
          "#{resource_group_path(resource_group)}/providers/Microsoft.Compute/#{type}/#{escape(name)}"
        end

        # @param value [String]
        # @return [String] path-escaped
        def escape(value)
          URI::DEFAULT_PARSER.escape(value.to_s)
        end

        # Performs an authenticated ARM request.
        #
        # Throttled (429) requests are retried for every method. Server errors
        # are retried only for idempotent methods. Each retry waits for the
        # server's +Retry-After+ when given, otherwise for an exponential
        # backoff with jitter.
        #
        # @param method [Symbol]
        # @param path [String] path below the resource manager URL.
        # @param api_version [String]
        # @param body [Hash, nil] request body, serialized as JSON.
        # @param allow [Array<Integer>] non-2xx statuses to treat as success.
        # @return [Http::Response]
        # @raise [OperationError] when ARM returns an unexpected status.
        def call(method, path, api_version:, body: nil, allow: [])
          url = "#{environment.resource_manager_url.chomp("/")}#{path}?api-version=#{api_version}"
          payload = body && JSON.generate(body)
          attempt = 0

          loop do
            response = Http.request(method:, url:, headers: request_headers(body), body: payload)
            return response if response.success? || allow.include?(response.status)

            unless attempt < max_retries && retryable?(method, response.status)
              raise OperationError.new(
                "Azure returned HTTP #{response.status} for #{method.to_s.upcase} #{path}",
                status: response.status,
                body: error_body(response)
              )
            end

            delay = retry_delay(response, attempt)
            attempt += 1
            @logger&.warn("Azure returned HTTP #{response.status} for #{method.to_s.upcase} #{path}; " \
                          "retrying in #{delay.round(1)}s (retry #{attempt} of #{max_retries}).")
            pause(delay)
          end
        end

        # Headers for one request. Built per attempt so a refreshed token is
        # picked up on retry.
        #
        # @param body [Hash, nil]
        # @return [Hash{String => String}]
        def request_headers(body)
          headers = {
            "Authorization" => token_provider.authorization_header,
            "Accept" => "application/json",
            "User-Agent" => "kitchen-azurerm/#{Kitchen::Driver::AZURERM_VERSION}",
          }
          headers["Content-Type"] = "application/json" if body
          headers
        end

        # @param method [Symbol]
        # @param status [Integer]
        # @return [Boolean] whether the failed request should be tried again.
        def retryable?(method, status)
          return true if THROTTLED_STATUSES.include?(status)

          SERVER_ERROR_STATUSES.include?(status) && IDEMPOTENT_METHODS.include?(method)
        end

        # Seconds to wait before the next attempt.
        #
        # @param response [Http::Response]
        # @param attempt [Integer] zero-based count of retries so far.
        # @return [Float]
        def retry_delay(response, attempt)
          retry_after = parse_retry_after(response.header("retry-after"))
          return retry_after.clamp(1, MAX_RETRY_AFTER).to_f if retry_after

          ceiling = [BASE_DELAY * (2**attempt), MAX_DELAY].min.to_f
          (ceiling / 2) + (rand * ceiling / 2)
        end

        # @param value [String, nil] seconds or an HTTP date.
        # @return [Numeric, nil]
        def parse_retry_after(value)
          return nil if value.nil? || value.strip.empty?
          return Integer(value.strip, 10) if value.strip.match?(/\A\d+\z/)

          Time.httpdate(value.strip) - Time.now
        rescue ArgumentError
          nil
        end

        # @param seconds [Float]
        # @return [void]
        def pause(seconds)
          sleep(seconds)
        end

        # @param response [Http::Response]
        # @return [Hash] the parsed error body, or a synthesized one.
        def error_body(response)
          parsed = response.json
          return parsed if parsed.is_a?(Hash) && parsed.key?("error")

          { "error" => { "code" => "Unknown", "message" => response.body.to_s } }
        end
      end
    end
  end
end
