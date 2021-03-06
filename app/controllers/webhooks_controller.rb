class WebhooksController < ApplicationController
  protect_from_forgery with: :null_session

  # rubocop:disable Metrics/CyclomaticComplexity
  def pull_request
    body = JSON.parse(request.body.read)

    senders_filter = Setting.lookup("senders_filter")
    if senders_filter.present?
      policy = ExclusionPolicy.new(
        senders_filter,
        Setting.lookup("senders_filter_policy")
      )
      unless policy.permitted?(body["sender"]["login"])
        head :ok
        return
      end
    end

    branch_filter = Setting.lookup("branch_filter")
    if branch_filter.present?
      policy = ExclusionPolicy.new(
        branch_filter,
        Setting.lookup("branch_filter_policy")
      )
      unless policy.permitted?(body["pull_request"]["base"]["ref"])
        head :ok
        return
      end
    end

    if body["action"] == "opened" || body["action"] == "synchronize" || body["action"] == "closed"
      ReceivePullRequestEvent.perform_async(body)
    end

    head :accepted
  end
  # rubocop:enable Metrics/CyclomaticComplexity

  def issue_comment
    body = JSON.parse(request.body.read)

    if body.key?("zen")
      head :ok
      return
    end

    ReceiveIssueCommentEvent.perform_async(body)
    head :accepted
  end

  # The entry point for webhooks from the GitHub app
  def integration
    body = JSON.parse(request.body.read)

    if body.key?("zen")
      head :ok
      return
    end

    request.body.rewind

    event = request.headers["X-GitHub-Event"]
    case event
    when "pull_request"
      pull_request
      return
    when "issue_comment"
      issue_comment
      return
    end

    head :accepted
  end
end
