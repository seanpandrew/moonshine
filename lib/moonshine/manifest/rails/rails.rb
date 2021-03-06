require 'pathname'
module Moonshine::Manifest::Rails::Rails

  # Attempt to bootstrap your application. Calls <tt>rake moonshine:bootstrap</tt>
  # which runs:
  #
  #   rake db:schema:load (if db/schema.rb exists)
  #   rake db:migrate (if db/migrate exists)
  #
  # We then run a task to load bootstrap fixtures from <tt>db/bootstrap</tt>
  # (if it exists). These fixtures may be created with the included
  # <tt>moonshine:db:bootstrap:dump</tt> rake task.
  #
  #   rake moonshine:db:bootstrap
  #
  # We then run the following task:
  #
  #   rake moonshine:app:bootstrap
  #
  # The <tt>moonshine:app:bootstrap</tt> task does nothing by default. If
  # you'd like to have your application perform any logic on its first deploy,
  # overwrite this task in your <tt>Rakefile</tt>:
  #
  #   namespace :moonshine do
  #     namespace :app do
  #       desc "Overwrite this task in your app if you have any bootstrap tasks that need to be run"
  #       task :bootstrap do
  #         #
  #       end
  #     end
  #   end
  #
  # All of this assumes one thing: that your application can run <tt>rake
  # environment</tt> with an empty database. Please ensure your application can
  # do so!
  def rails_bootstrap
    rake 'moonshine:bootstrap',
      :alias => 'rails_bootstrap',
      :refreshonly => true,
      :before => exec('rake db:migrate')
  end

  # Runs Rails migrations. These are run on each deploy to ensure consistency!
  # No more 500s when you forget to <tt>cap deploy:migrations</tt>
  def rails_migrations
    rake 'db:migrate'
  end

  # Rotates the logs for this rails app
  def rails_logrotate
    configure(:rails_logrotate => {})
    logrotate("#{configuration[:deploy_to]}/shared/log/*.log", {
      :options => configuration[:rails_logrotate][:options] || %w(daily missingok compress delaycompress sharedscripts),
      :postrotate => configuration[:rails_logrotate][:postrotate] || "touch #{configuration[:deploy_to]}/current/tmp/restart.txt"
    })
    file "/etc/logrotate.d/#{configuration[:deploy_to].gsub('/','')}sharedlog.conf", :ensure => :absent
  end

  # This task ensures Rake is installed and that <tt>rake environment</tt>
  # executes without error in your <tt>rails_root</tt>.
  def rails_rake_environment
    rake_version = configuration[:rake_version] || :installed
    package 'rake', :provider => :gem, :ensure => rake_version
    # we override these opts to avoid self-referential requires. probably best to not touch this.
    rake 'environment --trace',
      :alias => "rake tasks",
      :require => [exec('rails_gems')],
      :logoutput => :on_failure
  end

  # Automatically install all gems needed specified in the array at
  # <tt>configuration[:gems]</tt>. This loads gems from
  # <tt>config/gems.yml</tt>, which can be generated from by running
  # <tt>rake moonshine:gems</tt> locally.
  def rails_gems
    gemrc = HashWithIndifferentAccess.new({
      :verbose => true,
      :gem => '--no-ri --no-rdoc',
      :update_sources => true,
      :sources => [
        'http://rubygems.org',
        'http://gems.github.com'
      ]
     })
     gemrc.merge!(configuration[:rubygems]) if configuration[:rubygems]
     file '/etc/gemrc',
      :ensure   => :present,
      :mode     => '744',
      :owner    => 'root',
      :group    => 'root',
      :content  => gemrc.to_hash.to_yaml

    # stub for puppet dependencies
    exec 'rails_gems', :command => 'true'

    gemfile_path = rails_root.join('Gemfile')
    if gemfile_path.exist?
      # Bundler is initially installed by deploy:setup in the ruby:install_moonshine_deps task
      configure(:bundler => {})

      sandbox_environment do
        require 'bundler'
        ENV['BUNDLE_GEMFILE'] = gemfile_path.to_s
        Bundler.load

        # FIXME this method doesn't take into account dependencies's dependencies
        bundler = if Bundler::VERSION.to_f < 1.0
                   Bundler.runtime
                  else
                   Bundler.load
                  end
        bundler_dependencies = bundler.dependencies.select {|d| ([:default, rails_env.to_sym] & d.groups).any? }
        bundler_dependencies.each do |dependency|
          system_dependencies = configuration[:apt_gems][dependency.name.to_s] || []
          system_dependencies.each do |system_dependency|
            package system_dependency,
              :ensure => :installed,
              :before => exec('bundle install')
          end
        end
      end

      bundle_install_without_groups = configuration[:bundler] && configuration[:bundler][:install_without_groups] || "development test"
      bundle_install_options = [
         '--deployment',
         "--path #{configuration[:deploy_to]}/shared/bundle",
         "--without '#{bundle_install_without_groups}'"
      ]

      unless configuration[:bundler][:disable_binstubs]
        bundle_install_options << '--binstubs'
      end

      exec 'accept github key',
        :command => 'ssh git@github.com -o StrictHostKeyChecking=no || true',
        :before => exec('bundle install'),
        :user => configuration[:user],
        :unless => 'ssh-keygen -F github.com | grep github.com'

      exec 'bundle install',
        :command => "bundle install #{bundle_install_options.join(' ')}",
        :cwd => rails_root,
        :before => exec('rails_gems'),
        :require => file('/etc/gemrc'),
        :user => configuration[:user],
        :timeout => 108000,
        :logoutput => :on_failure

    else
      return unless configuration[:gems]
      configuration[:gems].each do |gem|
        gem(gem[:name], {
          :version => gem[:version],
          :source => gem[:source]
        })
      end
    end
  end

  # Essentially replicates the deploy:setup command from capistrano, but sets
  # up permissions correctly.
  def rails_directories
    deploy_to_array = configuration[:deploy_to].split('/').split('/')
    deploy_to_array.each_with_index do |dir, index|
      next if index == 0 || index >= (deploy_to_array.size-1)
      file '/'+deploy_to_array[1..index].join('/'), :ensure => :directory
    end
    dirs = [
      "#{configuration[:deploy_to]}",
      "#{configuration[:deploy_to]}/shared",
      "#{configuration[:deploy_to]}/releases"
    ]
    if configuration[:shared_children].is_a?(Array)
      shared_children_with_parents = configuration[:shared_children].map do |d|
        d.split("/").inject([]) {|these_dirs, dir| these_dirs.empty? ? [dir] : these_dirs << "#{these_dirs.last}/#{dir}" }
      end.flatten
      dirs += shared_children_with_parents.map {|d| "#{configuration[:deploy_to]}/shared/#{d}" }
    end

    if configuration[:app_symlinks].is_a?(Array)
      dirs += ["#{configuration[:deploy_to]}/shared/public"]
      symlink_dirs = configuration[:app_symlinks].map { |d| "#{configuration[:deploy_to]}/shared/public/#{d}" }
      dirs += symlink_dirs
    end

    dirs.each do |dir|
      file dir,
      :ensure => :directory,
      :owner => configuration[:user],
      :group => configuration[:group] || configuration[:user],
      :mode => '775'
    end
  end

  def rails_asset_pipeline
    file "#{configuration[:deploy_to]}/shared/assets",
      :ensure => :directory,
      :owner => configuration[:user],
      :group => configuration[:group] || configuration[:user],
      :mode => '775'
    file "#{rails_root}/public/assets",
      :ensure => "#{configuration[:deploy_to]}/shared/assets",
      :owner => configuration[:user],
      :require => file("#{configuration[:deploy_to]}/shared/assets")
    rake 'assets:precompile',
      :require => [file("#{rails_root}/public/assets"), exec('rails_gems')]
  end

  # Creates package("#{name}") with <tt>:provider</tt> set to <tt>:gem</tt>.
  # The given <tt>options[:version]</tt> requirement is tweaked to ensure
  # gems aren't reinstalled on each run. <tt>options[:source]</tt> does what
  # you'd expect, as well.
  #
  # === Gem Package Dependencies
  #
  # System dependencies are loaded if any exist for the gem or any of it's
  # gem dependencies in <tt>apt_gems.yml</tt>. For example, calling
  # <tt>gem('webrat')</tt> knows to install <tt>libxml2-dev</tt> and
  # <tt>libxslt1-dev</tt> because those are defined as dependencies for
  # <tt>nokogiri</tt>.
  #
  # To define system dependencies not include in moonshine:
  #
  #   class UrManifest < ShadowPuppet::Manifest
  #     configure(:apt_gems => {
  #       :fakegem => [
  #         'package1',
  #         'package2
  #       ]
  #     })
  #   end
  #
  # If you were then to require the installation of <tt>fakegem</tt> <strong>
  # or any gem that depends on <tt>fakegem</tt></strong>, <tt>package1</tt>
  # and <tt>package2</tt> would be installed first via apt.
  def gem(name, options = {})
    hash = {
      :provider => :gem,
      :before   => exec('rails_gems'),
      :require  => file('/etc/gemrc')
    }
    hash.merge!(:source => options[:source]) if options[:source]
    hash.merge!(:alias => options[:alias]) if options[:alias]
    #fixup the version required
    exact_dep = Gem::Dependency.new(name, options[:version] || '>0')
    if Gem::Specification.respond_to?(:find_all_by_name)
      matches = Gem::Specification.find_all_by_name(name)
    else
      matches = Gem.source_index.search(exact_dep)
    end
    installed_spec = matches.first
    if installed_spec
      if options[:version]
        #if it's not installed and version specified, we require that version
        hash.merge!(:ensure => options[:version])
      else
        #it's already loaded, let's just specify that we want it installed
        hash.merge!(:ensure => :installed)
      end
    else
      if options[:version]
        #if it's not installed and version specified, we require that version
        hash.merge!(:ensure => options[:version])
      else
        #otherwise we don't care
        hash.merge!(:ensure => :installed)
      end
      hash = append_system_dependecies(exact_dep, hash)
    end
    hash.delete(:version)
    package(name, hash)
  end

  private
  def append_system_dependecies(exact_dep, hash) #:nodoc:
    #fixup the requires key to be an array
    if hash[:require] && !hash[:require].is_a?(Array)
      hash[:require] = [hash[:require]]
    end
    hash[:require] = [] unless hash[:require]
    # load this gems' dependencies. we don't create packages for em, we just
    # check them against the system dependency map
    specs = Gem::SpecFetcher.fetcher.fetch exact_dep
    spec = specs.first.first
    deps = spec.dependencies
    deps << exact_dep
    deps.each do |dep|
      (configuration[:apt_gems][dep.name.to_sym] || []).each do |apt|
        package apt, :ensure => :installed
        hash[:require] << package(apt)
      end
    end
    hash.delete(:require) if hash[:require] == []
    hash
  rescue
    hash
  end

  # Creates exec("rake #name") that runs in <tt>rails root</tt> of the rails
  # app, with RAILS_ENV properly set
  def rake(name, options = {})
    exec("#{try_bundle_exec}rake #{name}", {
      :command => "#{try_bundle_exec}rake #{name}",
      :alias => "rake #{name}",
      :user => configuration[:user],
      :cwd => rails_root,
      :environment => "RAILS_ENV=#{ENV['RAILS_ENV']}",
      :require => exec('rake tasks'),
      :logoutput => true,
      :timeout => 108000
    }.merge(options)
  )
  end

  def try_bundle_exec
    gemfile_path = rails_root.join('Gemfile')
    if gemfile_path.exist?
      'bundle exec '
    else
      ''
    end
  end

  # Creates a sandbox environment so that ENV changes are reverted afterwards
  OLDENV = {}
  def sandbox_environment
    OLDENV.replace(ENV)
    ENV.replace({})
    yield
    ENV.replace(OLDENV)
  end
end
