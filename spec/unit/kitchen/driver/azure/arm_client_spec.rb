RSpec.describe Kitchen::Driver::Azure::ArmClient do
  subject(:client) do
    described_class.new(subscription_id:, environment:, token_provider: token_provider_double)
  end

  let(:subscription_id) { "115b12cb-b0d3-4ed9-94db-f73733be6f3c" }
  let(:environment) { Kitchen::Driver::Azure::Environments.fetch("Azure") }
  let(:base) { "https://management.azure.com/subscriptions/#{subscription_id}" }
  let(:resources_version) { described_class::RESOURCES_API_VERSION }
  let(:network_version) { described_class::NETWORK_API_VERSION }
  let(:compute_version) { described_class::COMPUTE_API_VERSION }

  def token_provider_double
    instance_double(Kitchen::Driver::Azure::TokenProvider, authorization_header: "Bearer a-token")
  end

  # Retries must never sleep for real in a unit test.
  before { allow(client).to receive(:pause) }

  describe "request framing" do
    it "authenticates every request" do
      stub = stub_request(:get, "#{base}/resourcegroups/rg/providers/Microsoft.Resources/deployments/d")
        .with(query: { "api-version" => resources_version }, headers: { "Authorization" => "Bearer a-token" })
        .to_return(status: 200, body: "{}")

      client.deployment("rg", "d")
      expect(stub).to have_been_requested
    end

    it "identifies itself" do
      stub = stub_request(:get, %r{/deployments/d})
        .with(headers: { "User-Agent" => "kitchen-azurerm/#{Kitchen::Driver::AZURERM_VERSION}" })
        .to_return(status: 200, body: "{}")

      client.deployment("rg", "d")
      expect(stub).to have_been_requested
    end

    it "escapes names that need it" do
      stub = stub_request(:head, "#{base}/resourcegroups/my%20group")
        .with(query: hash_including({}))
        .to_return(status: 204)

      client.resource_group_exists?("my group")
      expect(stub).to have_been_requested
    end
  end

  describe "#resource_group_exists?" do
    it "is true for a 204" do
      stub_request(:head, "#{base}/resourcegroups/rg").with(query: hash_including({})).to_return(status: 204)
      expect(client.resource_group_exists?("rg")).to be true
    end

    # A 404 is the API's way of saying "no", not a failure.
    it "is false for a 404" do
      stub_request(:head, "#{base}/resourcegroups/rg").with(query: hash_including({})).to_return(status: 404)
      expect(client.resource_group_exists?("rg")).to be false
    end

    it "raises for anything else" do
      stub_request(:head, "#{base}/resourcegroups/rg").with(query: hash_including({})).to_return(status: 403)
      expect { client.resource_group_exists?("rg") }.to raise_error(Kitchen::Driver::Azure::OperationError)
    end
  end

  describe "#create_or_update_resource_group" do
    it "PUTs the location and tags" do
      stub = stub_request(:put, "#{base}/resourcegroups/rg")
        .with(query: hash_including({}),
          body: { "location" => "eastus2", "tags" => { "owner" => "platform" } },
          headers: { "Content-Type" => "application/json" })
        .to_return(status: 200, body: '{"id":"/subscriptions/s/resourcegroups/rg"}')

      result = client.create_or_update_resource_group("rg", location: "eastus2", tags: { "owner" => "platform" })
      expect(stub).to have_been_requested
      expect(result["id"]).to eq("/subscriptions/s/resourcegroups/rg")
    end

    it "sends an empty tag object when given none" do
      stub = stub_request(:put, "#{base}/resourcegroups/rg")
        .with(query: hash_including({}), body: { "location" => "eastus2", "tags" => {} })
        .to_return(status: 200, body: "{}")

      client.create_or_update_resource_group("rg", location: "eastus2", tags: nil)
      expect(stub).to have_been_requested
    end
  end

  describe "#delete_resource_group" do
    it "DELETEs and returns without waiting" do
      stub = stub_request(:delete, "#{base}/resourcegroups/rg").with(query: hash_including({})).to_return(status: 202)
      expect(client.delete_resource_group("rg")).to be_nil
      expect(stub).to have_been_requested
    end

    # Deleting a group that is already gone is the outcome the caller wanted.
    # Raising here wedged `kitchen destroy` permanently for any instance whose
    # resource group had been removed out of band.
    it "treats a group that is already gone as deleted" do
      stub_request(:delete, "#{base}/resourcegroups/rg").with(query: hash_including({}))
        .to_return(status: 404, body: '{"error":{"code":"ResourceGroupNotFound","message":"could not be found."}}')

      expect(client.delete_resource_group("rg")).to be_nil
    end
  end

  describe "#create_deployment" do
    it "PUTs the deployment body" do
      body = { "properties" => { "mode" => "Incremental", "template" => { "resources" => [] } } }
      stub = stub_request(:put, "#{base}/resourcegroups/rg/providers/Microsoft.Resources/deployments/deploy-1")
        .with(query: { "api-version" => resources_version }, body:)
        .to_return(status: 201, body: '{"id":"/deployments/deploy-1"}')

      client.create_deployment("rg", "deploy-1", body)
      expect(stub).to have_been_requested
    end
  end

  describe "#deployment_operations" do
    it "unwraps the value array" do
      stub_request(:get, "#{base}/resourcegroups/rg/providers/Microsoft.Resources/deployments/d/operations")
        .with(query: hash_including({}))
        .to_return(status: 200, body: '{"value":[{"properties":{"statusCode":"OK"}}]}')

      expect(client.deployment_operations("rg", "d")).to eq([{ "properties" => { "statusCode" => "OK" } }])
    end

    it "is an empty array when ARM returns no value key" do
      stub_request(:get, %r{/operations}).to_return(status: 200, body: "{}")
      expect(client.deployment_operations("rg", "d")).to eq([])
    end

    it "is an empty array when ARM returns something that is not an object" do
      stub_request(:get, %r{/operations}).to_return(status: 200, body: "[]")
      expect(client.deployment_operations("rg", "d")).to eq([])
    end
  end

  describe "#virtual_machine_instance_view" do
    it "GETs the instance view with the compute API version" do
      stub = stub_request(:get, "#{base}/resourcegroups/rg/providers/Microsoft.Compute/virtualMachines/vm/instanceView")
        .with(query: { "api-version" => compute_version })
        .to_return(status: 200, body: '{"statuses":[{"code":"PowerState/running"}]}')

      expect(client.virtual_machine_instance_view("rg", "vm")).to eq("statuses" => [{ "code" => "PowerState/running" }])
      expect(stub).to have_been_requested
    end
  end

  describe "#subscription" do
    it "GETs the subscription itself" do
      stub = stub_request(:get, "https://management.azure.com/subscriptions/#{subscription_id}")
        .with(query: { "api-version" => described_class::SUBSCRIPTION_API_VERSION })
        .to_return(status: 200, body: %({"subscriptionId":"#{subscription_id}","displayName":"Testing"}))

      expect(client.subscription["displayName"]).to eq("Testing")
      expect(stub).to have_been_requested
    end
  end

  describe "network resources" do
    it "reads a public IP with the network API version" do
      stub = stub_request(:get, "#{base}/resourcegroups/rg/providers/Microsoft.Network/publicIPAddresses/publicip")
        .with(query: { "api-version" => network_version })
        .to_return(status: 200, body: '{"properties":{"ipAddress":"40.121.0.1"}}')

      expect(client.public_ip("rg", "publicip").dig("properties", "ipAddress")).to eq("40.121.0.1")
      expect(stub).to have_been_requested
    end

    it "reads a network interface" do
      stub_request(:get, "#{base}/resourcegroups/rg/providers/Microsoft.Network/networkInterfaces/nic-1")
        .with(query: hash_including({}))
        .to_return(status: 200, body: '{"name":"nic-1"}')

      expect(client.network_interface("rg", "nic-1")["name"]).to eq("nic-1")
    end
  end

  describe "error handling" do
    it "surfaces the Azure error code" do
      stub_request(:put, %r{/deployments/d}).to_return(
        status: 409,
        body: '{"error":{"code":"DeploymentActive","message":"already running"}}'
      )

      expect { client.create_deployment("rg", "d", {}) }
        .to raise_error(Kitchen::Driver::Azure::OperationError) { |e|
          expect(e.code).to eq("DeploymentActive")
          expect(e.status).to eq(409)
          expect(e.body.dig("error", "message")).to eq("already running")
        }
    end

    it "synthesizes a body when Azure returns something unparseable" do
      stub_request(:get, %r{/deployments/d}).to_return(status: 500, body: "<html>gateway blew up</html>")

      expect { client.deployment("rg", "d") }
        .to raise_error(Kitchen::Driver::Azure::OperationError) { |e|
          expect(e.code).to eq("Unknown")
          expect(e.body.dig("error", "message")).to include("gateway blew up")
        }
    end

    it "names the operation that failed" do
      stub_request(:delete, %r{/resourcegroups/rg}).to_return(status: 403, body: "{}")
      expect { client.delete_resource_group("rg") }.to raise_error(/HTTP 403 for DELETE/)
    end
  end

  describe "throttling and server errors" do
    let(:deployment_url) { %r{/deployments/d} }
    let(:logger) { instance_double(Logger, warn: nil) }

    subject(:client) do
      described_class.new(subscription_id:, environment:, token_provider: token_provider_double, logger:)
    end

    it "retries a 429 and returns the later success" do
      stub = stub_request(:get, deployment_url)
        .to_return({ status: 429, body: "", headers: { "Retry-After" => "7" } }, { status: 200, body: '{"name":"d"}' })

      expect(client.deployment("rg", "d")["name"]).to eq("d")
      expect(stub).to have_been_requested.twice
      expect(client).to have_received(:pause).with(7.0)
    end

    # ARM's own guidance: a throttled request was not processed, so even a
    # PUT can be sent again.
    it "retries a throttled PUT" do
      stub = stub_request(:put, deployment_url)
        .to_return({ status: 429, body: "" }, { status: 201, body: "{}" })

      client.create_deployment("rg", "d", { "properties" => {} })
      expect(stub).to have_been_requested.twice
    end

    it "honours an HTTP-date Retry-After" do
      stub_request(:get, deployment_url)
        .to_return({ status: 429, headers: { "Retry-After" => (Time.now + 30).httpdate } }, { status: 200, body: "{}" })

      client.deployment("rg", "d")
      expect(client).to have_received(:pause).with(be_within(2).of(30))
    end

    it "caps a very long Retry-After" do
      stub_request(:get, deployment_url)
        .to_return({ status: 429, headers: { "Retry-After" => "3600" } }, { status: 200, body: "{}" })

      client.deployment("rg", "d")
      expect(client).to have_received(:pause).with(described_class::MAX_RETRY_AFTER.to_f)
    end

    it "backs off exponentially with jitter when no Retry-After is given" do
      stub_request(:get, deployment_url).to_return(status: 429, body: "")
      delays = []
      allow(client).to receive(:pause) { |seconds| delays << seconds }

      expect { client.deployment("rg", "d") }.to raise_error(Kitchen::Driver::Azure::OperationError)
      ceilings = [2, 4, 8, 16, 32, 60]
      expect(delays.size).to eq(ceilings.size)
      delays.zip(ceilings).each { |delay, ceiling| expect(delay).to be_between(ceiling / 2.0, ceiling) }
    end

    it "gives up after max_retries and raises the last status" do
      stub = stub_request(:get, deployment_url).to_return(status: 429, body: "")

      expect { client.deployment("rg", "d") }.to raise_error(/HTTP 429 for GET/)
      expect(stub).to have_been_requested.times(described_class::DEFAULT_MAX_RETRIES + 1)
    end

    it "logs each retry" do
      stub_request(:get, deployment_url).to_return({ status: 429 }, { status: 200, body: "{}" })

      client.deployment("rg", "d")
      expect(logger).to have_received(:warn).with(/HTTP 429 for GET .*retry 1 of 6/)
    end

    it "retries a 503 on a GET" do
      stub = stub_request(:get, deployment_url).to_return({ status: 503 }, { status: 200, body: "{}" })

      client.deployment("rg", "d")
      expect(stub).to have_been_requested.twice
    end

    # A PUT that failed on the server side may still have been applied, so
    # repeating it is left to the caller.
    it "does not retry a 500 on a PUT" do
      stub = stub_request(:put, deployment_url).to_return(status: 500, body: "{}")

      expect { client.create_deployment("rg", "d", {}) }.to raise_error(/HTTP 500 for PUT/)
      expect(stub).to have_been_requested.once
    end

    it "does not retry a client error" do
      stub = stub_request(:get, deployment_url).to_return(status: 403, body: "{}")

      expect { client.deployment("rg", "d") }.to raise_error(/HTTP 403/)
      expect(stub).to have_been_requested.once
    end

    it "fetches the token again on each attempt" do
      provider = token_provider_double
      retrying = described_class.new(subscription_id:, environment:, token_provider: provider)
      allow(retrying).to receive(:pause)
      stub_request(:get, deployment_url).to_return({ status: 429 }, { status: 200, body: "{}" })

      retrying.deployment("rg", "d")
      expect(provider).to have_received(:authorization_header).twice
    end
  end

  describe "sovereign clouds" do
    let(:environment) { Kitchen::Driver::Azure::Environments.fetch("AzureUSGovernment") }

    it "targets that cloud's resource manager" do
      stub = stub_request(:get, "https://management.usgovcloudapi.net/subscriptions/#{subscription_id}/resourcegroups/rg/providers/Microsoft.Resources/deployments/d")
        .with(query: hash_including({}))
        .to_return(status: 200, body: "{}")

      client.deployment("rg", "d")
      expect(stub).to have_been_requested
    end
  end
end
