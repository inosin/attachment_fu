module Technoweenie
  module AttachmentFu
    module Backends
    # = Qiniu Storage Backend

      module QiniuBackend
        class RequiredLibraryNotFoundError < StandardError; end
        class ConfigFileNotFoundError < StandardError; end
        class ImageUploadFail < StandardError; end

        def self.included(base) #:nodoc:
          base.before_update :rename_file

          mattr_reader :qiniu_config

          begin
            require 'qiniu-rs'
            include Qiniu::RS
          rescue LoadError
            raise RequiredLibraryNotFoundError.new('Qiniu::RS could not be loaded')
          end

          begin
            @@qiniu_config_path = base.attachment_options[:qiniu_config_path] || (RAILS_ROOT + '/config/qiniu.yml')
            @@qiniu_config = YAML.load_file(@@qiniu_config_path)[RAILS_ENV].symbolize_keys
          rescue
            raise ConfigFileNotFoundError.new('File %s not found' % @@qiniu_config_path)
          end

          Qiniu::RS.establish_connection! qiniu_config.slice(:access_key, :secret_key)
        end

        # Overwrites the base filename writer in order to store the old filename
        def filename=(value)
          @old_filename = filename unless filename.nil? || @old_filename
          write_attribute :filename, sanitize_filename(value)
        end

        # The attachment ID used in the full path of a file
        def attachment_path_id
          ((respond_to?(:parent_id) && parent_id) || id).to_s
        end

        # by default paritions files into directories e.g. 0000/0001/image.jpg
        # to turn this off set :partition => false
        def partitioned_path(*args)
          if respond_to?(:attachment_options) && attachment_options[:partition] == false
            args
          else
            ("%08d" % attachment_path_id).scan(/..../) + args
          end
        end

        # The pseudo hierarchy containing the file relative to the bucket name
        # Example: <tt>:table_name/:id</tt>
        def base_path
          File.join(attachment_options[:path_prefix], attachment_path_id)
        end

        # The full path to the file relative to the bucket name
        # Example: <tt>:table_name/:id/:filename</tt>
        def full_filename(thumbnail = nil)
          File.join(base_path, thumbnail_name_for(thumbnail))
        end

        def qiniu_url(thumbnail = nil)
          File.join(qiniu_config[:distribution_domain], full_filename(thumbnail))
        end
        alias :public_filename :qiniu_url

        protected
          # Called in the after_destroy callback
          def destroy_file
            Qiniu::RS.delete(qiniu_config[:bucket_name], full_filename)
          end

          #TODO: 存储时已改名为uuid格式文件名存储，单独改文件名时只会修改数据库中filename字段，远程文件名不再修改
          def rename_file
            return unless @old_filename && @old_filename != filename
            return if !@old_filename || @old_filename == filename
            old_full_filename = File.join(base_path, @old_filename)

            # Qiniu::RS.move(
            #   qiniu_config[:bucket_name],
            #   old_full_filename,
            #   qiniu_config[:bucket_name],
            #   full_filename

            @old_filename = nil
            true
          end

          def save_to_storage
            if save_attachment?
              res = Qiniu::RS.upload_file :uptoken => qiniu_upload_token,
                           :file => temp_path,
                           :mime_type => content_type,
                           :bucket => qiniu_config[:bucket_name],
                           :key => full_filename
              if res.is_a?(Hash) && res['hash']
                return filename
              else
                raise ImageUploadFail, '上传文件失败: 七牛云返回结果异常'
              end
            end
            @old_filename = nil
            true
          end

          def qiniu_upload_token
            @upload_token ||= Qiniu::RS.generate_upload_token :scope => qiniu_config[:bucket_name]
          end

      end
    end
  end
end