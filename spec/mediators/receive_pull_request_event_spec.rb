require 'rails_helper'

RSpec.describe ReceivePullRequestEvent do
  let(:payload) do
    from_fixture = json_fixture("pull_request")
    from_fixture["action"] = action
    from_fixture["pull_request"]["body"] = body
    from_fixture
  end

  let(:job) { ReceivePullRequestEvent.new }

  let(:body) do
    "- [ ] @aergonaut\n- [ ] @BrentW\n"
  end

  describe "#perform" do
    before do
      stub_request(:post, %r(https?://api.github.com/repos/[A-Za-z0-9_-]+/[A-Za-z0-9_-]+/statuses/[0-9abcdef]{40}))
      stub_request(:patch, %r{https?://api.github.com/repos/[A-Za-z0-9_-]+/[A-Za-z0-9_-]+/issues/\d+})
      stub_request(:get, %r{https?://api.github.com/repos/[A-Za-z0-9_-]+/[A-Za-z0-9_-]+/pulls/\d+}).to_return(
        status: 200,
        headers: { 'Content-Type' => 'application/json' },
        body: File.open(Rails.root.join("spec", "fixtures", "pr.json"))
      )
      stub_request(:get, %r{https?://api.github.com/repos/[A-Za-z0-9_-]+/[A-Za-z0-9_-]+/collaborators/[A-Za-z0-9_-]+}).to_return(status: 204)
    end

    context "when the action is \"opened\"" do
      let(:action) { "opened" }

      context "when a minimum number of reviewers is required" do
        let(:min_reviewers) { 2 }

        before do
          allow(Setting).to receive(:lookup).and_call_original
          expect(Setting).to receive(:lookup).with("minimum_reviewers_required", payload["pull_request"]["base"]["repo"]["full_name"]).and_return(min_reviewers).at_least(:once)
        end

        context "and the PR does not have enough" do
          let(:min_reviewers) { 3 }

          it "puts the failure status on the commit" do
            job.perform(payload)
            expect(WebMock).to have_requested(:post, %r(https?://api.github.com/repos/[A-Za-z0-9_-]+/[A-Za-z0-9_-]+/statuses/[0-9abcdef]{40})).
              with { |req| JSON.load(req.body)["state"] == "failure" }
          end

          it "does not make a new PullRequest record" do
            expect { job.perform(payload) }.to_not change { PullRequest.count }
          end
        end

        context "and there aren't enough unique reviewers" do
          let(:body) do
            "- [ ] @BrentW\n- [ ] @BrentW\n"
          end

          it "puts the failure status on the commit" do
            job.perform(payload)
            expect(WebMock).to have_requested(:post, %r(https?://api.github.com/repos/[A-Za-z0-9_-]+/[A-Za-z0-9_-]+/statuses/[0-9abcdef]{40})).
              with { |req| JSON.load(req.body)["state"] == "failure" }
          end
        end
      end

      context "when no fatal errors are raised" do
        before do
          apply_rules = instance_double(ApplyReviewRules)
          expect(apply_rules).to receive(:perform)
          expect(ApplyReviewRules).to receive(:new).and_return(apply_rules)
        end

        it "creates a new PullRequest" do
          expect { job.perform(payload) }.to change { PullRequest.count }.by(1)
        end

        context "when some reviewers have already approved" do
          let(:body) do
            "- [ ] @aergonaut\n- [x] @BrentW\n"
          end

          it "creates Reviewers appropriately for each reviewer" do
            job.perform(payload)
            expect(PullRequest.last.reviewers.pending_review.map(&:login)).to contain_exactly("aergonaut")
            expect(PullRequest.last.reviewers.completed_review.map(&:login)).to contain_exactly("BrentW")
          end
        end

        context "when all of the reviewers have already approved" do
          let(:body) do
            "- [x] @aergonaut\n- [x] @BrentW\n"
          end

          it "marks the status as approved" do
            job.perform(payload)
            expect(PullRequest.last.status).to eq("approved")
          end
        end

        it "sends a POST request to GitHub" do
          job.perform(payload)
          expect(WebMock).to have_requested(:post, %r(https?://api.github.com/repos/[A-Za-z0-9_-]+/[A-Za-z0-9_-]+/statuses/[0-9abcdef]{40}))
        end
      end
    end

    context "when the action is \"synchronize\"" do
      let(:action) { "synchronize" }

      context "and we have recorded the PR" do
        let!(:pr) { FactoryBot.create :pull_request, number: payload["number"], repository: payload['repository']['full_name'], status: status }

        before do
          job.perform(payload)
        end

        context "and the PR is pending" do
          let(:status) { "pending_review" }

          it "sends the pending review comment in the body" do
            expect(WebMock).to have_requested(:post, %r(https?://api.github.com/repos/[A-Za-z0-9_-]+/[A-Za-z0-9_-]+/statuses/[0-9abcdef]{40})).
              with { |req| JSON.load(req.body)["description"] == "Not all reviewers have approved" }
          end
        end

        context "and the PR is approved" do
          let(:status) { "approved" }

          it "sends the review complete comment in the body" do
            expect(WebMock).to have_requested(:post, %r(https?://api.github.com/repos/[A-Za-z0-9_-]+/[A-Za-z0-9_-]+/statuses/[0-9abcdef]{40})).
              with { |req| JSON.load(req.body)["description"] == "Code review complete" }
          end
        end
      end

      context "and we haven't yet recorded the PR" do
        it "delegates to CreateOrUpdatePullRequest" do
          expect(CreateOrUpdatePullRequest).to receive(:new).and_call_original
          job.perform(payload)
        end
      end
    end
  end
end
