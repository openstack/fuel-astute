#    Copyright 2013 Mirantis, Inc.
#
#    Licensed under the Apache License, Version 2.0 (the "License"); you may
#    not use this file except in compliance with the License. You may obtain
#    a copy of the License at
#
#         http://www.apache.org/licenses/LICENSE-2.0
#
#    Unless required by applicable law or agreed to in writing, software
#    distributed under the License is distributed on an "AS IS" BASIS, WITHOUT
#    WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied. See the
#    License for the specific language governing permissions and limitations
#    under the License.


module Astute
  module Dump
    def self.dump_environment(ctx, settings)
      shell = MClient.new(
        ctx,
        'execute_shell_command',
        ['master'],
        check_result=true,
        settings['timeout'] || Astute.config.dump_timeout,
        retries=0,
        enable_result_logging=false
      )

      upload_file = MClient.new(ctx, 'uploadfile', ['master'])
      begin
        config_path = '/tmp/dump_config'
        upload_file.upload(
          :path => config_path,
          :content => settings.to_json,
          :user_owner => 'root',
          :group_owner => 'root',
          :overwrite => true)

        dump_cmd = "shotgun -c #{config_path} > /dev/null 2>&1 && cat #{settings['lastdump']}"
        Astute.logger.debug("Try to execute command: #{dump_cmd}")
        result = shell.execute(:cmd => dump_cmd).first.results

        Astute.logger.debug("#{ctx.task_id}: exit code: #{result[:data][:exit_code]}")

        if result[:data][:exit_code] == 0
          Astute.logger.info("#{ctx.task_id}: Snapshot is done.")
          report_success(ctx, result[:data][:stdout].rstrip)
        else
          Astute.logger.error("#{ctx.task_id}: Dump command returned non zero exit code. For details see /var/log/docker-logs/shotgun.log")
          report_error(ctx, "exit code: #{result[:data][:exit_code]} stderr: #{result[:data][:stderr]}")
        end
      rescue Timeout::Error
        msg = "Dump is timed out"
        Astute.logger.error("#{ctx.task_id}: #{msg}")
        report_error(ctx, msg)
      rescue => e
        msg = "Exception occured during dump task: message: #{e.message} \
trace:\n#{e.backtrace.pretty_inspect}"
        Astute.logger.error("#{ctx.task_id}: #{msg}")
        report_error(ctx, msg)
      end
    end

    def self.report_success(ctx, msg=nil)
      success_msg = {'status' => 'ready', 'progress' => 100}
      success_msg.merge!({'msg' => msg}) if msg
      ctx.reporter.report(success_msg)
    end

    def self.report_error(ctx, msg)
      ctx.reporter.report({'status' => 'error', 'error' => msg, 'progress' => 100})
    end

  end
end
