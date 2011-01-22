# This file is covered by the Ruby license. See COPYING for more details.
# Copyright (C) 2009-2010, Apple Inc. All rights reserved.

require 'jcd'
require 'stringio'
require 'mongrel'

module ControlTower
  class RackSocket
    VERSION = [1,0].freeze

    def initialize(host, port, server, concurrent)
      @app = server.app
      @socket = TCPServer.new(host, port)
      @socket.listen(50)
      @status = :closed # Start closed and give the server time to start

      if concurrent
        @multithread = true
        @request_queue = Dispatch::Queue.concurrent
        puts "Caution! Wake turbulance from heavy aircraft landing on parallel runway.\n(Parallel Request Action ENABLED!)"
      else
        @multithread = false
        @request_queue = Dispatch::Queue.new('com.apple.ControlTower.rack_socket_queue')
      end
      @request_group = Dispatch::Group.new
    end

    def open
      @status = :open
      @classifier = Mongrel::URIClassifier.new
      while (@status == :open)
        conn = @socket.accept
        
        conn.tap do |connection|
          @request_queue.async(@request_group) do
            begin
              request, response = parse!(connection)
              if request
                env = {}.replace(request.params)
                env.delete "HTTP_CONTENT_TYPE"
                env.delete "HTTP_CONTENT_LENGTH"
                
                env["SCRIPT_NAME"] = ""  if env["SCRIPT_NAME"] == "/"
                
                rack_input = request.body || StringIO.new('')
                rack_input.set_encoding(Encoding::BINARY) if rack_input.respond_to?(:set_encoding)
                
                env.update({"rack.version" => Rack::VERSION,
                  "rack.input" => rack_input,
                  "rack.errors" => $stderr,
                  
                  "rack.multithread" => true,
                  "rack.multiprocess" => false, # ???
                  "rack.run_once" => false,
                  
                  "rack.url_scheme" => "http",
                  })
                  env["QUERY_STRING"] ||= ""
                  
                  status, headers, body = @app.call(env)
                  
                begin
                  response.status = status.to_i
                  response.send_status(nil)
                  
                  headers.each { |k, vs|
                    vs.split("\n").each { |v|
                      response.header[k] = v
                    }
                  }
                  response.send_header
                  
                  body.each { |part|
                    response.write part
                    response.socket.flush
                  }
                ensure
                  body.close  if body.respond_to? :close
                end
                
              else
                $stderr.puts "Error: No request data received!"
              end
            rescue EOFError, Errno::ECONNRESET, Errno::EPIPE, Errno::EINVAL
              $stderr.puts "Error: Connection terminated!"
            rescue Object => e
              if response.nil? && !connection.closed?
                connection.write "HTTP/1.1 400\r\n\r\n"
              else
                # We have a response, but there was trouble sending it:
                $stderr.puts "Error: Problem transmitting data -- #{e.inspect}"
                $stderr.puts e.backtrace.join("\n")
              end
            ensure
              # We should clean up after our tempfile, if we used one.
              # input = env['rack.input']
              # input.unlink if input.class == Tempfile
              connection.close rescue nil
            end
          end
        end
      end
    end

    def close
      @status = :close

      # You get 30 seconds to empty the request queue and get outa here!
      Dispatch::Source.timer(30, 0, 1, Dispatch::Queue.concurrent) do
        $stderr.puts "Timed out waiting for connections to close"
        exit 1
      end
      @request_group.wait
      @socket.close
    end


    private

    def parse!(client)
      begin
        parser = Mongrel::HttpParser.new
        params = Mongrel::HttpParams.new
        request = nil
        data = client.readpartial(Mongrel::Const::CHUNK_SIZE)
        nparsed = 0

        # Assumption: nparsed will always be less since data will get filled with more
        # after each parsing.  If it doesn't get more then there was a problem
        # with the read operation on the client socket.  Effect is to stop processing when the
        # socket can't fill the buffer for further parsing.
        while nparsed < data.length
          nparsed = parser.execute(params, data, nparsed)

          if parser.finished?
            if not params[Mongrel::Const::REQUEST_PATH]
              # it might be a dumbass full host request header
              uri = URI.parse(params[Mongrel::Const::REQUEST_URI])
              params[Mongrel::Const::REQUEST_PATH] = uri.path
            end

            raise "No REQUEST PATH" if not params[Mongrel::Const::REQUEST_PATH]

            script_name, path_info, handlers = @classifier.resolve(params[Mongrel::Const::REQUEST_PATH])
            
            params[Mongrel::Const::PATH_INFO] = path_info
            params[Mongrel::Const::SCRIPT_NAME] = script_name

            # From http://www.ietf.org/rfc/rfc3875 :
            # "Script authors should be aware that the REMOTE_ADDR and REMOTE_HOST
            #  meta-variables (see sections 4.1.8 and 4.1.9) may not identify the
            #  ultimate source of the request.  They identify the client for the
            #  immediate request to the server; that client may be a proxy, gateway,
            #  or other intermediary acting on behalf of the actual source client."
            params[Mongrel::Const::REMOTE_ADDR] = client.peeraddr.last
            
            notifiers = []
            request = Mongrel::HttpRequest.new(params, client, notifiers)

            # in the case of large file uploads the user could close the socket, so skip those requests
            raise "closed request" if request.body == nil  # nil signals from HttpRequest::initialize that the request was aborted

            # request is good so far, continue processing the response
            response = Mongrel::HttpResponse.new(client)
            
            return request, response
          else
            # Parser is not done, queue up more data to read and continue parsing
            chunk = client.readpartial(Mongrel::Const::CHUNK_SIZE)
            break if !chunk or chunk.length == 0  # read failed, stop processing

            data << chunk
            if data.length >= Mongrel::Const::MAX_HEADER
              raise Mongrel::HttpParserError.new("HEADER is longer than allowed, aborting client early.")
            end
          end
        end
      rescue Mongrel::HttpParserError => e
        STDERR.puts "#{Time.now}: HTTP parse error, malformed request (#{params[Mongrel::Const::HTTP_X_FORWARDED_FOR] || client.peeraddr.last}): #{e.inspect}"
        STDERR.puts "#{Time.now}: REQUEST DATA: #{data.inspect}\n---\nPARAMS: #{params.inspect}\n---\n"
      rescue Exception => e
        STDERR.puts "#{Time.now}: Read error: #{e.inspect}"
        STDERR.puts e.backtrace.join("\n")
      end
    end
  end
end
