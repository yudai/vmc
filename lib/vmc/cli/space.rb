require "vmc/cli"

module VMC
  class Space < CLI
    def precondition
      check_target
      check_logged_in

      fail "This command is v2-only." unless v2?
    end

    def self.by_name(what, obj = what)
      proc { |name, *_|
        client.send(:"#{obj}_by_name", name) ||
          fail("Unknown #{what} '#{name}'")
      }
    end

    def self.space_by_name
      proc { |name, org, *_|
        org.spaces(1, :name => name).first ||
          fail("Unknown space '#{name}'")
      }
    end

    desc "Show space information"
    group :spaces
    input :organization, :aliases => ["--org", "-o"],
      :from_given => by_name("organization"),
      :default => proc { client.current_organization },
      :desc => "Space's organization"
    input :space, :argument => :optional,
      :from_given => space_by_name,
      :default => proc { client.current_space },
      :desc => "Space to show"
    input :full, :type => :boolean,
      :desc => "Show full information for apps, service instances, etc."
    def space
      org = input[:organization]
      space = input[:space, org]

      unless space
        return if quiet?
        fail "No current space."
      end

      if quiet?
        puts space.name
        return
      end

      line "#{c(space.name, :name)}:"

      indented do
        line "organization: #{c(space.organization.name, :name)}"

        if input[:full]
          line
          line "apps:"

          spaced(space.apps(2)) do |a|
            indented do
              invoke :app, :app => a
            end
          end
        else
          line "apps: #{name_list(space.apps)}"
        end

        if input[:full]
          line
          line "services:"
          spaced(space.service_instances(2)) do |i|
            indented do
              invoke :service, :instance => i
            end
          end
        else
          line "services: #{name_list(space.service_instances)}"
        end

        line "domains: #{name_list(space.domains)}"
      end
    end


    desc "List spaces in an organization"
    group :spaces
    input :organization, :argument => :optional, :aliases => ["--org", "-o"],
      :from_given => by_name("organization"),
      :default => proc { client.current_organization },
      :desc => "Organization to list spaces from"
    input :name, :desc => "Filter by name"
    input :one_line, :alias => "-l", :type => :boolean, :default => false,
      :desc => "Single-line tabular format"
    input :full, :type => :boolean, :default => false,
      :desc => "Show full information for apps, service instances, etc."
    def spaces
      org = input[:organization]
      spaces =
        with_progress("Getting spaces in #{c(org.name, :name)}") do
          org.spaces(1)
        end

      line unless quiet?

      spaces.reject! do |s|
        !space_matches(s, input)
      end

      if input[:one_line]
        table(
          %w{name apps services},
          spaces.collect { |s|
            [ c(s.name, :name),
              name_list(s.apps),
              name_list(s.service_instances)
            ]
          })
      else
        spaced(spaces) do |s|
          invoke :space, :space => s, :full => input[:full]
        end
      end
    end


    desc "Create a space in an organization"
    group :spaces
    input(:name, :argument => :optional, :desc => "Space name") {
      ask("Name")
    }
    input :organization, :argument => :optional, :aliases => ["--org", "-o"],
      :from_given => by_name("organization"),
      :default => proc { client.current_organization },
      :desc => "Parent organization"
    input :target, :alias => "-t", :type => :boolean,
      :desc => "Switch to the space after creation"
    input :manager, :type => :boolean, :default => true,
      :desc => "Add current user as manager"
    input :developer, :type => :boolean, :default => true,
      :desc => "Add current user as developer"
    input :auditor, :type => :boolean, :default => false,
      :desc => "Add current user as auditor"
    def create_space
      space = client.space
      space.organization = input[:organization]
      space.name = input[:name]

      with_progress("Creating space #{c(space.name, :name)}") do
        space.create!
      end

      if input[:manager]
        with_progress("Adding you as a manager") do
          space.add_manager client.current_user
        end
      end

      if input[:developer]
        with_progress("Adding you as a developer") do
          space.add_developer client.current_user
        end
      end

      if input[:auditor]
        with_progress("Adding you as an auditor") do
          space.add_auditor client.current_user
        end
      end

      if input[:target]
        invoke :target, :organization => space.organization,
          :space => space
      end
    end


    desc "Switch to a space, creating it if it doesn't exist"
    group :spaces, :hidden => true
    input :name, :argument => true, :desc => "Space name"
    def take_space
      if space = client.space_by_name(input[:name])
        invoke :target, :space => space
      else
        invoke :create_space, :name => input[:name], :target => true
      end
    end


    desc "Delete a space and its contents"
    group :spaces
    input(:spaces, :argument => :splat,
          :from_given => space_by_name,
          :desc => "Space to delete") { |org|
      spaces = org.spaces
      fail "No spaces." if spaces.empty?

      [ask("Which space in #{c(org.name, :name)}?", :choices => spaces,
           :display => proc(&:name))]
    }
    input :organization, :aliases => ["--org", "-o"],
      :from_given => by_name("organization"),
      :default => proc { client.current_organization },
      :desc => "Space's organization"
    input(:really, :type => :boolean, :forget => true,
          :default => proc { force? || interact }) { |space|
      ask("Really delete #{c(space.name, :name)}?", :default => false)
    }
    input(:recursive, :alias => "-r", :type => :boolean, :forget => true) {
      ask "Delete #{c("EVERYTHING", :bad)}?", :default => false
    }
    input :warn, :type => :boolean, :default => true,
      :desc => "Show warning if it was the last space"
    def delete_space
      org = input[:organization]
      spaces = input[:spaces, org]

      deleted_current = false

      spaces.each do |space|
        next unless input[:really, space]

        next unless clear_space(space)

        deleted_current ||= space == client.current_space

        with_progress("Deleting space #{c(space.name, :name)}") do
          space.delete!
        end
      end

      org.invalidate!

      if org.spaces.empty?
        return unless input[:warn]

        line
        line c("There are no longer any spaces in #{b(org.name)}.", :warning)
        line "You may want to create one with #{c("create-space", :good)}."
      elsif deleted_current
        invalidate_client
        invoke :target, :organization => client.current_organization
      end
    end

    private

    def space_matches(s, options)
      if name = options[:name]
        return false if s.name !~ /#{name}/
      end

      true
    end

    def clear_space(space)
      apps = space.apps
      instances = space.service_instances

      return true if apps.empty? && instances.empty?

      unless force?
        line "This space is not empty!"
        line
        line "apps: #{name_list(apps)}"
        line "service instances: #{name_list(instances)}"
        line

        return unless input[:recursive]
      end

      apps.each do |a|
        invoke :delete, :app => a, :really => true
      end

      instances.each do |i|
        invoke :delete_service, :instance => i, :really => true
      end

      true
    end
  end
end
