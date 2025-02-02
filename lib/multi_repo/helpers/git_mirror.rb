module MultiRepo::Helpers
  class GitMirror
    def initialize
      require "colorize"
      require "config"

      @errors_occurred = false
    end

    def settings
      @settings ||= Config.load_files(MultiRepo.config_dir.join("settings.yml").to_s, MultiRepo.config_dir.join("settings.local.yml").to_s)
    end

    def mirror_all
      settings.git_mirror.repos_to_mirror.keys.each { |repo| mirror(repo) }
      !@errors_occurred
    end

    def mirror(repo)
      repo = repo.to_s
      options = default_repo_options.dup.merge!(settings.git_mirror.repos_to_mirror[repo].to_h)
      with_repo(repo, options) do
        send("mirror_#{options.remote_source}_repo", repo)
      end
      !@errors_occurred
    end

    private

    def default_repo_options
      Config::Options.new(:remote_source => :upstream)
    end

    def backup_remote_defined?
      !!settings.git_mirror.remotes.backup
    end

    def mirror_branches_for(repo)
      settings.git_mirror.branch_mirror_defaults.to_h.merge(settings.git_mirror.branch_mirror_overrides[repo].to_h || {}).each_with_object({}) { |(k, v), h| h[k.to_s] = v }
    end

    def mirror_branches(repo, source_remote, dest_remote)
      mirror_branches_for(repo).each do |source_name, dest_name|
        sync_branch(source_remote, source_name, dest_remote, dest_name)
      end
    end

    def mirror_upstream_repo(repo)
      mirror_remote_refs(repo, "upstream", "downstream")
      mirror_branches(repo, "upstream", "downstream")
      mirror_remote_refs(repo, "downstream", "backup") if backup_remote_defined?
    end

    def mirror_downstream_repo(repo)
      mirror_branches(repo, "downstream", "downstream")
      mirror_remote_refs(repo, "downstream", "backup") if backup_remote_defined?
    end

    def dry_run?
      return @dry_run if defined?(@dry_run)
      @dry_run = ARGV.include?("--dry-run")
    end

    def downstream_repo_name(repo, options)
      options.downstream_repo_name || repo.sub(/^manageiq/, settings.git_mirror.productization_name)
    end

    def system(*args)
      puts "+ #{"dry_run: " if dry_run?}#{args.join(" ")}"
      return true if dry_run?

      args << {} unless args.last.is_a?(Hash)
      args.last[[:out, :err]] = ["/tmp/mirror_helper_out", "w"]

      super.tap do |result|
        unless result
          @errors_occurred = true
          STDERR.puts "!!! An error has occurred:\n#{File.read("/tmp/mirror_helper_out")}".bold.red
        end
      end
    end

    def with_repo(repo, options)
      repo_name = downstream_repo_name(repo, options)
      puts "\n==== Mirroring #{repo_name} ====".bold.cyan

      working_dir = settings.git_mirror.working_directory
      FileUtils.mkdir_p(working_dir)

      path = "#{working_dir}/#{repo_name}"
      clone_repo(repo, repo_name, path, options.remote_source) unless File.directory?(path)

      Dir.chdir(path) do
        puts "\n==== Fetching for #{repo_name} ====".bold.green
        # Enforce an order for remote fetching to ensure that moved
        #   tags prefer what is on upstream
        system("git fetch backup --prune --tags") if backup_remote_defined? && remote_exists?("backup")
        system("git fetch downstream --prune --tags")
        system("git fetch upstream --prune --tags") if [:red_hat_cloudforms, :upstream].include?(options.remote_source)

        yield
      end

      puts
    end

    def clone_repo(upstream_repo, downstream_repo, path, remote_source)
      upstream_remote = settings.git_mirror.remotes[remote_source]
      raise "remote '#{remote_source}'' not found in settings" if upstream_remote.nil?

      system("git clone #{upstream_remote}/#{upstream_repo}.git #{path} -o upstream")
      Dir.chdir(path) do
        unless remote_exists?("downstream")
          downstream_remote = settings.git_mirror.remotes.downstream
          raise "remote 'downstream' not found in settings" if downstream_remote.nil?

          system("git remote add downstream #{downstream_remote}/#{downstream_repo}.git")
        end
        if backup_remote_defined? && !remote_exists?("backup")
          backup_remote = settings.git_mirror.remotes.backup
          system("git remote add backup #{backup_remote}/#{downstream_repo}.git")
        end
      end
    end

    def remote_refs(repo, remote)
      return unless remote_exists?(remote)

      `git ls-remote #{remote} | grep "heads"`.split("\n").collect do |line|
        branch = line.split("/").last
        next if remote == "upstream" && !upstream_branch?(repo, branch)
        "#{remote}/#{branch}:refs/heads/#{branch}"
      end.compact.join(" ")
    end

    def remote_exists?(remote)
      `git ls-remote #{remote} --exit-code 2>/dev/null`
      $? == 0
    end

    def upstream_branch?(repo, branch)
      (mirror_branches_for(repo).keys.collect(&:to_s) + ["master"]).include?(branch)
    end

    def remote_branch?(branch)
      !`git branch -r | grep "\\b#{branch}\\b"`.strip.empty?
    end

    def sync_branch(source_remote, source_name, dest_remote, dest_name)
      return unless dest_remote && dest_name

      source_fq_name = "#{source_remote}/#{source_name}"
      dest_fq_name   = "#{dest_remote}/#{dest_name}"

      puts "\n==== Syncing #{source_name} to #{dest_name} ====".bold.green
      unless remote_branch?(source_fq_name)
        puts "! Skipping sync of #{source_name} to #{dest_name} since #{source_fq_name} branch does not exist".yellow
        return
      end

      start_point = remote_branch?(dest_fq_name) ? dest_fq_name : source_fq_name
      system("git rebase --abort || true") # `git rebase --abort` will exit non-zero if there's nothing to abort
      system("git reset --hard")

      success =
        system("git checkout -B #{dest_name} #{start_point}") &&
        system("git pull --no-rebase #{source_remote} #{source_name}") &&
        system("git push -f #{dest_remote} #{dest_name}")

      if backup_remote_defined?
        if success && remote_exists?("backup")
          success = system("git push -f backup #{dest_name}")
        else
          puts "! Skipping sync of #{source_name} to backup/#{dest_name} since backup remote does not exist".yellow
        end
      end

      success
    end

    def mirror_remote_refs(repo, source_remote, dest_remote)
      puts "\n==== Mirroring #{source_remote} to #{dest_remote} ====".bold.green
      unless remote_exists?(dest_remote)
        puts "! Skipping mirror of #{source_remote} to #{dest_remote} since #{dest_remote} does not exist".yellow
        return
      end

      refs = remote_refs(repo, source_remote)
      if refs.to_s.strip.empty?
        puts "! Skipping mirror of #{source_remote} to #{dest_remote} since there are no refs to mirror".yellow
        return
      end

      system("git push #{dest_remote} #{refs}") &&
        system("git push -f #{dest_remote} --tags")
    end
  end
end
