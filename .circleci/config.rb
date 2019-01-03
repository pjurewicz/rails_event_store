require "yaml"

gems = %w(
  aggregate_root
  bounded_context
  ruby_event_store
  ruby_event_store-browser
  ruby_event_store-rom
  rails_event_store
  rails_event_store_active_record
  rails_event_store_active_record-legacy
  rails_event_store-rspec
)

database_url = ->(gem_name) {
  case gem_name
  when /active_record/
    "sqlite3:db.sqlite3"
  when /rom/
    "sqlite:db.sqlite3"
  else
    "sqlite3::memory:"
  end
}

test_gem_job_name = ->(gem_name, ruby_version) {"test_#{gem_name}_#{ruby_version}".gsub('-', '_').gsub('.', '_')}
test_gem_job      = ->(gem_name, ruby_version, docker_image) do
  {
    test_gem_job_name.(gem_name, ruby_version) => {
      "docker" => [
        {
          "environment" => {
            "DATABASE_URL" => database_url.(gem_name)
          },
          "image" => docker_image
        }
      ],
      "steps"  => [
        "checkout",
        { "run" => "cd #{gem_name} && make install test" }
      ]
    }
  }
end
ruby_2_3_compatibility = gems.inject({}) {|config, gem_name| config.merge(test_gem_job.(gem_name, '2.3', 'pawelpacana/res:2.3.8'))}
ruby_2_4_compatibility = gems.inject({}) {|config, gem_name| config.merge(test_gem_job.(gem_name, '2.4', 'pawelpacana/res:2.4.5'))}
ruby_2_5_compatibility = gems.inject({}) {|config, gem_name| config.merge(test_gem_job.(gem_name, '2.5', 'pawelpacana/res:2.5.3'))}
current_ruby           = gems.inject({}) {|config, gem_name| config.merge(test_gem_job.(gem_name, '2.6', 'pawelpacana/res:2.6.0'))}

mutate_gem_job_name = ->(gem_name, ruby_version) {"mutate_#{gem_name}_#{ruby_version}".gsub('-', '_').gsub('.', '_')}
mutate_gem_job      = ->(gem_name, ruby_version, docker_image) do
  {
    mutate_gem_job_name.(gem_name, ruby_version) => {
      "docker" => [
        {
          "environment" => {
            "MUTANT_JOBS" => 4
          },
          "image"       => docker_image
        }
      ],
      "steps"  => [
        "checkout",
        { "run" => "cd #{gem_name} && make install mutate" }
      ]
    }
  }
end
mutation_jobs       = gems.inject({}) {|config, gem_name| config.merge(mutate_gem_job.(gem_name, '2.6', 'circleci/ruby:2.6.0-node-browsers'))}

dependent_job = ->(name, requires) do
  { name => { 'requires' => Array(requires) } }
end

check_config = {
  "check_config" => {
    "docker" => [
      { "image" => "pawelpacana/res:2.6.0" }
    ],
    "steps"  => [
      "checkout",
      "run" => {
        "name"    => "Verify .circleci/config.yml is generated by running ruby .circleci/config.rb",
        "command" => %q[WAS="$(md5sum .circleci/config.yml)" && ruby .circleci/config.rb && test "$WAS" == "$(md5sum .circleci/config.yml)"]
      }
    ]
  }
}

config =
  {
    "version"   => '2.1',
    "jobs"      => check_config
                     .merge(mutation_jobs)
                     .merge(current_ruby)
                     .merge(ruby_2_3_compatibility)
                     .merge(ruby_2_4_compatibility)
                     .merge(ruby_2_5_compatibility),
    "workflows" => {
      "version"             => 2,
      "Check configuration" => {
        "jobs" => %w(check_config)
      },
      "Current Ruby"        => {
        "jobs" => gems.flat_map {|name| [test_gem_job_name.(name, '2.6'), dependent_job.(mutate_gem_job_name.(name, '2.6'), test_gem_job_name.(name, '2.6'))]}
      },
      "Ruby 2.5"            => {
        "jobs" => gems.map {|name| test_gem_job_name.(name, '2.5')}
      },
      "Ruby 2.4"            => {
        "jobs" => gems.map {|name| test_gem_job_name.(name, '2.4')}
      },
      "Ruby 2.3"            => {
        "jobs" => gems.map {|name| test_gem_job_name.(name, '2.3')}
      }
    }
  }


File.open(".circleci/config.yml", "w") do |file|
  file << <<~EOS
    # This file is generated by .circleci/config.rb, do not edit it manually!
    # Edit .circleci/config.rb and run ruby .circleci/config.rb
  EOS
  file << YAML.dump(config).gsub("---", "")
end
