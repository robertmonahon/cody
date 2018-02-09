class CreateOrUpdatePullRequest
  include GithubApi

  # Public: Creates or updates a Pull Request record in reponse to a webhook
  #
  # pull_request - A Hash-like object containing the PR data from the GitHub API
  # options - Hash of options
  #           :skip_review_rules - Boolean to apply review rules or skip
  # rubocop:disable Metrics/LineLength, Metrics/CyclomaticComplexity, Metrics/MethodLength
  def perform(pull_request, options = {})
    pr = PullRequest.find_or_initialize_by(
      number: pull_request["number"],
      repository: pull_request["base"]["repo"]["full_name"]
    )

    github = github_client

    body = pull_request["body"] || ""

    if body =~ PullRequest::REVIEW_LINK_REGEX && pr.link_by_number($1)
      pr.update_status
      return
    end

    prelude, _ = body.split(ReviewRule::GENERATED_REVIEWERS_REGEX, 2)
    prelude ||= ""

    # Collect reviewers listed in the PR prelude.
    check_box_pairs = prelude.scan(PullRequest::REVIEWER_CHECKBOX_REGEX)

    # uniqueness by reviewer login
    check_box_pairs.uniq! { |pair| pair[1] }

    minimum_reviewers_required = Setting.lookup("minimum_reviewers_required", pull_request["base"]["repo"]["full_name"])
    if minimum_reviewers_required.present? &&
      check_box_pairs.count < minimum_reviewers_required

      pr.update_status(PullRequest::STATUS_APRICOT)
      return
    end

    pending_reviews = []
    completed_reviews = []

    check_box_pairs.each do |pair|
      if pair[0] == "x"
        completed_reviews << pair[1].strip
      else
        pending_reviews << pair[1].strip
      end
    end

    all_reviewers = pending_reviews + completed_reviews

    reviewers_without_access = pending_reviews.reject do |reviewer|
      github.collaborator?(pr.repository, reviewer)
    end

    unless reviewers_without_access.empty?
      verb_phrase =
        if reviewers_without_access.count > 1
          "are not collaborators"
        else
          "is not a collaborator"
        end

      reviewers_phrase = reviewers_without_access.join(", ")

      pr.update_status(PullRequest::STATUS_PLUM % { reviewers: reviewers_phrase, verb_phrase: verb_phrase })
      return
    end

    pr.status = "pending_review"

    pr.save!

    # Synchronize the reviewers
    all_reviewers.each do |login|
      # we only respect manual updates to non-generated reviewers
      reviewer = pr.reviewers.find_by(login: login, review_rule_id: nil)
      if reviewer.present?
        # they were on the list previously
        if completed_reviews.include?(login)
          # marked done
          reviewer.update!(status: Reviewer::STATUS_APPROVED)
        elsif pending_reviews.include?(login)
          # marked undone
          reviewer.update!(status: Reviewer::STATUS_PENDING_APPROVAL)
        else
          # removed from the list altogether
          reviewer.destroy!
        end
      # they weren't on the list previously
      elsif completed_reviews.include?(login)
        # marked down
        pr.reviewers.create!(login: login, status: Reviewer::STATUS_APPROVED)
      else
        # otherwise they're marked undone
        pr.reviewers.create!(
          login: login,
          status: Reviewer::STATUS_PENDING_APPROVAL
        )
      end
    end

    # Destroy reviewers who were on the list before but aren't any longer
    pr.reviewers
      .where(review_rule_id: nil)
      .where("reviewers.login NOT IN (?)", all_reviewers)
      .destroy_all

    unless options[:skip_review_rules]
      ApplyReviewRules.new(pr, pull_request).perform
    end

    pr.reload

    status =
      if !pr.reviewers.pending_review.empty?
        "pending_review"
      else
        "approved"
      end

    pr.status = status
    pr.save!

    pr.update_status
    pr.assign_reviewers
  end
end
