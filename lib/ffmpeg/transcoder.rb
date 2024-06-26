require 'open3'
require 'shellwords'

module FFMPEG
  class Transcoder
    @@timeout = 30

    def self.timeout=(time)
      @@timeout = time
    end

    def self.timeout
      @@timeout
    end

    def initialize(movie,
                   output_file,
                   options = EncodingOptions.new,
                   input_options = EncodingOptions.new,
                   transcoder_options = {})
      @movie = movie
      @output_file = output_file

      assign_input_options(input_options) if input_options
      assign_output_options(options) if options

      @transcoder_options = transcoder_options
      @errors = []

      apply_transcoder_options
    end

    def assign_input_options(input_options)
      if input_options.is_a?(String) || input_options.is_a?(EncodingOptions)
        @raw_input_options = input_options
      elsif input_options.is_a?(Hash)
        @raw_input_options = EncodingOptions.new(input_options)
      else
        raise ArgumentError, "Unknown input options format '#{input_options.class}', " \
                             "should be either EncodingOptions, Hash or String."
      end
    end

    def assign_output_options(options)
      if options.is_a?(String) || options.is_a?(EncodingOptions)
        @raw_options = options
      elsif options.is_a?(Hash)
        @raw_options = EncodingOptions.new(options)
      else
        raise ArgumentError, "Unknown options format '#{options.class}', " \
                             "should be either EncodingOptions, Hash or String."
      end
    end

    def run(&block)
      transcode_movie(&block)
      if @transcoder_options[:validate]
        validate_output_file(&block)
        return encoded
      else
        return nil
      end
    end

    def encoding_succeeded?
      @errors << "no output file created" and return false unless File.exist?(@output_file)
      @errors << "encoded file is invalid" and return false unless encoded.valid?
      true
    end

    def encoded
      @encoded ||= Movie.new(@output_file)
    end
    
    def transcode_command
      return @transcoder_options[:command] if @transcoder_options[:command]
      
      cmd = "#{FFMPEG.ffmpeg_binary} -y #{@raw_input_options} " \
            "#{detect_errors}" \
            "-i #{Shellwords.escape(@movie.path)} #{@raw_options}"
      
      return cmd unless @output_file
      
      cmd + Shellwords.escape(@output_file)
    end

    private
    
    def detect_errors
      @transcoder_options[:ignore_errors].to_s == 'true' ? '' : "-err_detect explode -xerror "
    end

    # frame= 4855 fps= 46 q=31.0 size=   45306kB time=00:02:42.28 bitrate=2287.0kbits/
    def transcode_movie(&block)
      @command = transcode_command

      FFMPEG.logger.info("Running transcoding...\n#{@command}\n")
      @output = ""

      Open3.popen3(@command) do |stdin, stdout, stderr, wait_thr|
        begin
          yield(0.0) if block_given?
          next_line = process_next_line(&block)
          if @@timeout
            stderr.each_with_timeout(wait_thr.pid, @@timeout, 'size=', &next_line)
          else
            stderr.each('size=', &next_line)
          end
        rescue Timeout::Error => e
          message = "Process hung...\nCommand: #{@command}\nOutput: #{@output}" \
            "\nMessage: #{e.message}\nBacktrace: #{e.backtrace}"
          FFMPEG.logger.error message
          raise StandardError, message
        rescue => e
          raise_ffmpeg_exception(e.message, e.backtrace)
        ensure
          raise_ffmpeg_exception(nil, nil) unless wait_thr.value.success?
        end
      end
    end

    def calculate_progress(line)
      if line =~ /time=(\d+):(\d+):(\d+.\d+)/ # ffmpeg 0.8 and above style
        time = ($1.to_i * 3600) + ($2.to_i * 60) + $3.to_f
      else # better make sure it wont blow up in case of unexpected output
        time = 0.0
      end
      progress = time / @movie.duration
      yield(progress) if block_given?
    end

    def process_next_line(&block)
      Proc.new do |line|
        fix_encoding(line)
        @output << line
        if line.include?("time=")
          calculate_progress(line, &block)
        elsif line.include?("Error while")
          raise StandardError, "ERROR in command: #{@command}, \nOutput: #{@output}"
        end
      end
    end

    def validate_output_file(&block)
      if encoding_succeeded?
        yield(1.0) if block_given?
        FFMPEG.logger.info "Transcoding of #{@movie.path} to #{@output_file} succeeded\n"
      else
        errors = "Errors: #{@errors.join(", ")}. "
        FFMPEG.logger.error "Failed encoding...\n#{@command}\n\n#{@output}\n#{errors}\n"
        raise Error, "Failed encoding.#{errors}Full output: #{@output}"
      end
    end

    def apply_transcoder_options
       # if true runs #validate_output_file
      @transcoder_options[:validate] = @transcoder_options.fetch(:validate) { true }
      return if @transcoder_options[:command] || @movie.calculated_aspect_ratio.nil?
      case @transcoder_options[:preserve_aspect_ratio].to_s
      when "width"
        new_height = @raw_options.width / @movie.calculated_aspect_ratio
        new_height = new_height.ceil.even? ? new_height.ceil : new_height.floor
        new_height += 1 if new_height.odd? # needed if new_height ended up with no decimals in the first place
        @raw_options[:resolution] = "#{@raw_options.width}x#{new_height}"
      when "height"
        new_width = @raw_options.height * @movie.calculated_aspect_ratio
        new_width = new_width.ceil.even? ? new_width.ceil : new_width.floor
        new_width += 1 if new_width.odd?
        @raw_options[:resolution] = "#{new_width}x#{@raw_options.height}"
      end
    end

    def fix_encoding(output)
      output[/test/]
    rescue ArgumentError
      output.force_encoding("ISO-8859-1")
    end

    def raise_ffmpeg_exception(message, backtrace)
      m = "ERROR Executing FFMPEG..." \
        "\nCommand: #{@command}" \
        "\nOutput: #{@output}"
      m << "\nMessage: #{message}" if message
      m << "\nBacktrace: #{backtrace}" if backtrace
      FFMPEG.logger.error m
      raise StandardError, m
    end
  end
end

