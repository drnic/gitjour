require 'rubygems'
require 'dnssd'
require 'set'
require 'socket'
require 'readline'
require 'gitjour/version'

Thread.abort_on_exception = true

module Gitjour
  class GitService < Struct.new(:name, :host, :port, :repository, :path, :description, :prefix)
    def url
      "git://#{host.gsub(/\.$/,"")}#{port == 9418 ? "" : ":#{port}"}/#{path}"
    end
    def search_content
      [name, host, repository, description, prefix]
    end
  end

  class Application

    class << self
      def run(*args)
        case args.shift
          when "list"
            list(*args)
          when "serve"
            serve(*args)
          when "search"
            search(*args)
          when "clone"
            clone(*args)
          when "remote"
            remote(*args)
          else
            help
        end
      end

      private      
      
      def service_list_display(service_list, *rest)
        @total_services = 0
        lines = []
        service_list.inject({}) do |service_by_repository, service|
          service_by_repository[service.repository] ||= []
          service_by_repository[service.repository] << service
          service_by_repository
        end.sort_by do |repository, _|
          repository
        end.each do |(repository, services)|
          local_services = services.select { |s| s.host == Socket.gethostname + "." }
          services -= local_services unless rest.include?("--local")
          @total_services += services.size
          lines << "=== #{repository} #{services.length > 1 ? "(#{services.length} copies)" : ""}" if services.size >= 1
          services.sort_by {|s| s.host}.each do |service|
            lines << "\t#{service.name} #{service.url}"
          end
        end
        lines
      end  
      
      def list(*rest)
        puts service_list_display(service_list, *rest)
        puts "#{@total_services} repositories shown." 
      end

      def serve(path=Dir.pwd, *rest)
        puts "SERVING!"
        path = File.expand_path(path)
        name = rest.shift
        port = rest.shift || 9418

        if File.exists?("#{path}/.git")
          @serving_multiple = false
          announce_repo(path, name, port.to_i)
        else
          Dir["#{path}/*"].each do |dir|
            @serving_multiple = true
            if File.directory?(dir)
              announce_repo(dir, name, 9418)
            end
          end
        end
        

        child = nil # Avoid races
        (1..15).each do |signal|
          Signal.trap(signal) do
            Process.kill(signal, child) if child
          end
        end
        child = fork {
          exec "git-daemon --verbose --export-all --port=#{port} --base-path=\"#{path}\" --base-path-relaxed"
        }
        Process.wait(child)
      end

      def search(term)
        puts service_list_display(service_list.select do |s|
          s.search_content.any? {|sc| sc =~ /#{term}/i }
        end).map {|s| $stdout.isatty ? s.gsub(/(#{term})/i, "\033[0;32m\\0\033[0m") : s }
      end
      
      def clone(name, label = nil, *rest)
        services = find_services(name)
        
        if services.empty? 
          puts "Cannot find any git repository with the name '#{name}'"
          exit(1)
        elsif services.size == 1
          service = services.first
          label ||= service.name
          puts "Cloning #{service.name}"
          system "git clone \"#{service.url}\" \"#{label}\""
        else
          puts "There is more than one repository matching that name. Please be more specific:"
          number = 0
          services.each do |service|
            number += 1
            puts "#{number}. #{service.name}"
          end
          repository = Readline::readline(">> ").to_i
          if services[repository-1].nil?
            puts "You specified an invalid repository"
            clone(name, label, *rest)
          else
            label = services[repository-1].name
            system "git clone \"#{services[repository-1].url}\" \"#{label}\""
          end
        end
      end
      
      def find_services(name)
        service_list.select { |s| /#{name}/.match(s.name.downcase) }
      end
      
      def find_service(name)
        service_list.detect { |s| /#{name}/.match(s.name.downcase) }
      end
      
      def remote(name, label = nil, *rest)
        service = find_service(name)
        
        unless service 
          puts "Cannot find the #{name} git repository"
          exit(1)
        end
        
        label ||= service.prefix.empty? ? name : service.prefix
        
        puts "Adding remote 'git remote add #{label} #{service.url}'"
        system "git remote add #{label} #{service.url}"
      end

      def help
        puts "Gitjour #{Gitjour::VERSION::STRING}"
        puts "Serve up and use git repositories via Bonjour/DNSSD."
        puts "\nUsage: gitjour <command> [args]"
        puts
        puts "  list"
        puts "      Lists available repositories."
        puts
        puts "  serve <path_to_project> [<name_of_project>] [<port>] or"
        puts "        <path_to_projects>"
        puts "      Serve up the current directory or projects via gitjour."
        puts
        puts "  clone <name_of_project> [<directory name>]"
        puts "      Clones the project into the chosen directory"
        puts
        puts "  remote <name_of_project> [<remote label>]"
        puts "      Adds a remote to the current git repository.  Optionally provide a label"
        puts "      to the remote repository."
        puts
        puts "      The name of your project is automatically prefixed with"
        puts "      `git config --get gitjour.prefix` or your username (preference"
        puts "      in that order). If you don't want a prefix, put a ^ on the front"
        puts "      of the name_of_project (the ^ is removed before announcing)."
        puts
        puts "  search <string>"
        puts "      Searches for your string in the name, host, repository, description,"
        puts "      and highlights it in sexy awesomeness (okay, we just colour it in a "
        puts "      little)."
        puts
      end

      def exit_with!(message)
        STDERR.puts message
        exit!
      end

      class Done < RuntimeError; end

      def discover(timeout=5)
        waiting_thread = Thread.current

        dns = DNSSD.browse "_git._tcp" do |reply|
          DNSSD.resolve reply.name, reply.type, reply.domain do |resolve_reply|
            service = GitService.new(reply.name,
                                     resolve_reply.target,
                                     resolve_reply.port,
                                     resolve_reply.text_record['repository'].to_s,
                                     resolve_reply.text_record['path'].to_s,
                                     resolve_reply.text_record['description'].to_s,
                                     resolve_reply.text_record['prefix'].to_s)
            begin
              yield service
            rescue Done
              waiting_thread.run
            end
          end
        end

        puts "Gathering for up to #{timeout} seconds..."
        sleep timeout
        dns.stop
      end

      def locate_repo(name)
        found = nil

        discover do |obj|
          if obj.name == name
            found = obj
            raise Done
          end
        end

        return found
      end

      def service_list
        return @list if @list
        @list = Set.new
        discover { |obj| @list << obj }
        return @list
      end


      def announce_repo(path, name, port)
        return unless File.exists?("#{path}/.git")
        
        # If the name's been given and it starts with ^, then don't apply the prefix
        if name && name[0] == ?^
          name[1..-1]
        else
          name = name || File.basename(path)
          prefix = `git config --get gitjour.prefix`.chomp
          prefix = ENV["USER"] if prefix.empty?
          name = [prefix, name].compact.join("-")
        end

        tr = DNSSD::TextRecord.new
        tr['description'] = File.read("#{path}/.git/description") rescue "a git project"
        tr['repository']  = File.basename(path)
        tr['path']        = @serving_multiple ? File.basename(path) : ""
        tr['prefix']        = prefix

        DNSSD.register(name, "_git._tcp", 'local', port, tr.encode) do |rr|
          puts "Registered #{name} on port #{port}. Starting service."
        end
      end

      private 
      def display_services(services)
        services.each do |service|
          # puts "=== #{service.name} on #{service.host}:#{service.port} ==="
          puts "  gitjour clone #{service.name} # #{service.host}:#{service.port}"
          # if service.description != '' && service.description !~ /^Unnamed repository/
          #   puts "  #{service.description}"
          # end
          # puts
        end
      end

    end
  end
end



