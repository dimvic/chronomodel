module ActiveRecord
  module Tasks
    class ChronomodelDatabaseTasks < PostgreSQLDatabaseTasks
      CHRONOMODEL_SCHEMAS = [
        ChronoModel::Adapter::TEMPORAL_SCHEMA,
        ChronoModel::Adapter::HISTORY_SCHEMA
      ].freeze

      def structure_dump(*arguments)
        if schema_search_path.present?
          with_chronomodel_schema_search_path { super }
        else
          super
        end

        # The structure.sql includes CREATE SCHEMA statements, but as these are executed
        # when the connection to the database is established, a db:structure:load fails.
        #
        # This code adds the IF NOT EXISTS clause to CREATE SCHEMA statements as long as
        # it is not already present.
        #
        filename = arguments.first
        sql = File.read(filename).gsub(/CREATE SCHEMA (?!IF NOT EXISTS)/, '\&IF NOT EXISTS ')
        File.open(filename, 'w') { |file| file << sql }

        remove_sql_header_comments(filename) if ActiveRecord::VERSION::STRING < '5.1'
      end

      def data_dump(target)
        psql_env

        args = ['-c', '-f', target.to_s]
        args << chronomodel_configuration[:database]

        run_cmd "pg_dump", args, 'dumping data'
      end

      def data_load(source)
        psql_env

        args = ['-f', source]
        args << chronomodel_configuration[:database]

        run_cmd "psql", args, 'loading data'
      end

      private

      # In Rails 6.1.x the configuration instance variable is not available
      # and it's been replaced by @configuration_hash (which is frozen).
      def chronomodel_configuration
        @chronomodel_configuration ||=
          if defined?(@configuration_hash)
            @configuration_hash
          else
            configuration.with_indifferent_access
          end
      end

      # If a schema search path is defined in the configuration file, it will
      # be used by the database tasks class to dump only the specified search
      # path. Here we add also ChronoModel's temporal and history schemas to
      # the search path and yield.
      #
      def with_chronomodel_schema_search_path
        patch_configuration!

        yield
      ensure
        reset_configuration!
      end

      def patch_configuration!
        @original_schema_search_path = schema_search_path

        chronomodel_schema_search_path = "#{schema_search_path},#{CHRONOMODEL_SCHEMAS.join(',')}"

        if defined?(@configuration_hash)
          @configuration_hash = @configuration_hash.dup
          @configuration_hash[:schema_search_path] = chronomodel_schema_search_path
          @configuration_hash.freeze
        else
          configuration['schema_search_path'] = chronomodel_schema_search_path
        end
      end

      def reset_configuration!
        if defined?(@configuration_hash)
          @configuration_hash = @configuration_hash.dup
          @configuration_hash[:schema_search_path] = @original_schema_search_path
          @configuration_hash.freeze
        else
          configuration['schema_search_path'] = @original_schema_search_path
        end
      end

      unless private_instance_methods.include?(:remove_sql_header_comments)
        def remove_sql_header_comments(filename)
          sql_comment_begin = '--'
          removing_comments = true
          tempfile = Tempfile.open("uncommented_structure.sql")
          begin
            File.foreach(filename) do |line|
              unless removing_comments && (line.start_with?(sql_comment_begin) || line.blank?)
                tempfile << line
                removing_comments = false
              end
            end
          ensure
            tempfile.close
          end
          FileUtils.mv(tempfile.path, filename)
        end
      end

      unless private_instance_methods.include?(:psql_env)
        alias psql_env set_psql_env
      end

      def schema_search_path
        @schema_search_path ||= chronomodel_configuration[:schema_search_path]
      end
    end
  end
end
