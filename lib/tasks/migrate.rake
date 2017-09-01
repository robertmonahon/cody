# rubocop:disable Metrics/BlockLength
namespace :data do
  desc "Migrate serialized reviewers to Reviewer model"
  task migrate_to_reviewer_model: :environment do
    if ENV["TESTING"]
      puts "TESTING! dropping all Reviewers"
      Reviewer.delete_all
    end

    github =
      if ENV["TESTING"]
        puts "TESTING! using netrc"
        Octokit::Client.new(netrc: true)
      else
        Octokit::Client.new(
          access_token: Rails.application.secrets.github_access_token
        )
      end

    PullRequest.pending_review.find_in_batches(batch_size: 500) do |batch|
      batch.each do |pull_request|
        next unless pull_request.reviewers.empty?

        pr_data = github.pull_request(
          pull_request.repository,
          pull_request.number
        )

        # don't care about stuff that's closed or merged already
        next if pr_data.state != "open"

        body = pr_data.body

        # Split the body on the Generated Reviewers header
        prelude, addendum = body.split(/^\s*#*\s*Generated\s*Reviewers\s*$/, 2)

        # Scan the beginning for reviewer check boxes
        prelude.scan(PullRequest::REVIEWER_CHECKBOX_REGEX)
          .each do |check_mark, reviewer_login|

          status =
            if check_mark == "x"
              Reviewer::STATUS_APPROVED
            else
              Reviewer::STATUS_PENDING_APPROVAL
            end

          pull_request.reviewers.find_or_create_by!(
            login: reviewer_login,
            review_rule_id: nil,
            status: status
          )
        end

        next unless addendum.present?

        # Split the addendum on H3 markdown tags.
        # These are indicative of a new Review Rule
        addendum.strip.split("### ").each do |part|
          next if part.blank?

          newline_index = part.index("\n")
          next unless newline_index.present?

          # The rule's name is all the characters up to the first newline
          rule_name = part[0...newline_index]

          rule = ReviewRule.find_by(name: rule_name)
          next unless rule.present?

          # There should only be 1 reviewer so just do a simple match
          next unless part =~ PullRequest::REVIEWER_CHECKBOX_REGEX

          status =
            if $1 == "x"
              Reviewer::STATUS_APPROVED
            else
              Reviewer::STATUS_PENDING_APPROVAL
            end

          reviewer_login = $2

          pull_request.reviewers.create!(
            login: reviewer_login,
            review_rule_id: rule.id,
            status: status
          )
        end
      end

      # let the API cool off
      sleep(rand(1..5))
    end
  end

  desc "Validates the migration of reviewers"
  task validate_migration_to_reviewer_model: :environment do
    PullRequest.pending_review.find_each do |pull_request|
      next if pull_request.reviewers.empty?

      pending_reviews = pull_request.reviewers.pending_review.map(&:login)
      completed_reviews = pull_request.reviewers.completed_review.map(&:login)

      puts pull_request.number
      puts "Pending Reviews"
      if pending_reviews != pull_request.pending_reviews
        puts "Migrated data: #{pending_reviews.inspect}"
        puts "Original data: #{pull_request.pending_reviews.inspect}"
      else
        puts "."
      end

      puts "Completed Reviews"
      if completed_reviews != pull_request.completed_reviews
        puts "Migrated data: #{completed_reviews.inspect}"
        puts "Original data: #{pull_request.completed_reviews.inspect}"
      else
        puts "."
      end
      puts
    end
  end

  desc "Move repositories from string columns into table"
  task migrate_repositories: :environment do
    pr_repos = PullRequest.uniq.pluck(:repository_name)
    pr_repos.each do |repo_name|
      owner, name = repo_name.split("/", 2)
      repo = Repository.find_or_create_by!(owner: owner, name: name)
      PullRequest.where(repository_name: repo_name).update(repository_id: repo.id)
    end
  end
end
