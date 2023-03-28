#!/usr/bin/env ruby

$LOAD_PATH << File.expand_path("../lib", __dir__)

require 'bundler/setup'
require 'multi_repo'
require 'optimist'

opts = Optimist.options do
  MultiRepo.common_options(self, :only => :dry_run)
end

github = MultiRepo::Service::Github.new(**opts.slice(:dry_run))

repos = (github.org_repo_names("ManageIQ") << "ManageIQ/rbvmomi2").sort
repos.each do |repo_name|
  puts MultiRepo.header(repo_name)

  disabled_workflows = github.disabled_workflows
  if disabled_workflows.any?
    disabled_workflows.each do |w|
      puts "** Enabling #{w.html_url} (#{w.id})"
      github.enable_workflow(github, repo_name, w.html_url, w.id)
    end
  else
    puts "** No disabled workflows found"
  end

  puts
end
