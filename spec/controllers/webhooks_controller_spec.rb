require 'rails_helper'

RSpec.describe WebhooksController, type: :controller do
  describe "POST pull_request" do
    let(:payload) do
      from_fixture = json_fixture("pull_request")
      from_fixture["action"] = action
      from_fixture
    end

    let(:action) { "opened" }

    context "when the action is \"opened\"" do
      it "delegates to ReceivePullRequestEvent" do
        expect { post :pull_request, body: JSON.dump(payload) }.to change(ReceivePullRequestEvent.jobs, :size).by(1)
      end
    end

    context "when the action is not \"opened\"" do
      let(:action) { "closed" }

      it "does not create a new ReceivePullRequestEvent job" do
        expect { post :pull_request, body: JSON.dump(payload) }.to_not change(ReceivePullRequestEvent.jobs, :size)
      end
    end

    it "returns 202 Accepted" do
      post :pull_request, body: JSON.dump(payload)
      expect(response.status).to be(202)
    end
  end

  describe "POST issue_comment" do
    let(:payload) { json_fixture("issue_comment") }

    it "creates a new ReceiveIssueCommentEvent job" do
      expect { post :issue_comment, body: JSON.dump(payload) }.to change(ReceiveIssueCommentEvent.jobs, :size).by(1)
    end

    it "returns 202 Accepted" do
      post :issue_comment, body: JSON.dump(payload)
      expect(response.status).to be(202)
    end
  end
end
