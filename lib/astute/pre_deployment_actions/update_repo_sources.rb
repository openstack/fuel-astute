#    Copyright 2014 Mirantis, Inc.
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
  class UpdateRepoSources < PreDeploymentAction

    # Update packages source list
    def process(deployment_info, context)
      return unless deployment_info.first['repo_setup']['repos']
      deployment_info = only_uniq_nodes(deployment_info)

      perform_with_limit(deployment_info) do |part|
        upload_repo_source(context, part)
        regenerate_metadata(context, part)
        if target_os(deployment_info) == 'ubuntu'
          upload_apt_proxy_conf(context, part)
        end
      end
    end

    private

    def generate_repo_source(deployment_info)
      ubuntu_source = -> (repo) do
        repo = ''
        repo += "# Repository: '#{repo['name']}'\n" if repo['name']
        repo += "deb #{repo['uri']} #{repo['suite']} #{repo['section']}\n"
        repo
      end

      centos_source = -> (repo) do
        repo = ''
        repo += "[#{repo['name'].downcase}]\n"
        repo += "name=#{repo['name']}\n"
        repo += "baseurl='#{repo['uri']}'\n"
        repo += "gpgcheck=0\n"
        if repo['proxy']
          repo['proxy'] += '/' unless repo['proxy'].end_with? '/'
          repo += "proxy='#{repo['proxy']}'\n"
        end
        repos
      end

      formatter = case target_os(deployment_info)
                  when 'centos' then centos_source
                  when 'ubuntu' then ubuntu_source
                  end

      content = []
      deployment_info.first['repo_setup']['repos'].each do |repo|
        content << formatter.call(repo)
      end
      content.join("\n")
    end

    def upload_repo_source(context, deployment_info)
      upload_mclient = MClient.new(context, "uploadfile", deployment_info.map{ |n| n['uid'] }.uniq)
      destination_path = case target_os(deployment_info)
                         when 'centos' then '/etc/yum.repos.d/nailgun.repo'
                         when 'ubuntu' then '/etc/apt/sources.list'
                         end
      upload_mclient.upload(:path => destination_path,
                      :content => generate_repo_source(deployment_info),
                      :user_owner => 'root',
                      :group_owner => 'root',
                      :permissions => '0644',
                      :dir_permissions => '0755',
                      :overwrite => true,
                      :parents => true
                     )
    end

    def generate_apt_proxy_conf(deployment_info)
      apt_conf = ''
      deployment_info.first['repo_setup']['repos'].each do |repo|
        proxy = repo['proxy']
        next unless proxy
        proxy += '/' unless proxy.end_with? '/'
        host = URI.parse(repo['uri']).host rescue nil
        next unless host
        apt_conf += "# Repository: '#{repo['name']}'\n" if repo['name']
        apt_conf += "Acquire::Http::Proxy::#{host} \"#{proxy}\";\n"
      end
      apt_conf
    end

    def upload_apt_proxy_conf(context, deployment_info)
      upload_mclient = MClient.new(context, "uploadfile", deployment_info.map{ |n| n['uid'] }.uniq)
      destination_path = '/etc/apt/apt.conf.d/90proxy'
      upload_mclient.upload(:path => destination_path,
                            :content => generate_apt_proxy_conf(deployment_info),
                            :user_owner => 'root',
                            :group_owner => 'root',
                            :permissions => '0644',
                            :dir_permissions => '0755',
                            :overwrite => true,
                            :parents => true
      )

    end

    def regenerate_metadata(context, deployment_info)
      cmd = case target_os(deployment_info)
            when 'centos' then "yum clean all"
            when 'ubuntu' then "apt-get clean; apt-get update"
            end

      succeeded = false
      nodes_uids = deployment_info.map{ |n| n['uid'] }.uniq
      Astute.config.mc_retries.times.each do
        succeeded = run_shell_command_remotely(context, nodes_uids, cmd)
        return if succeeded
        sleep Astute.config.mc_retry_interval
      end

      if !succeeded
        raise DeploymentEngineError, "Run command: '#{cmd}' in nodes: #{nodes_uids} fail." \
                                     " Check debug output for more information"
      end
    end

    def target_os(deployment_info)
      os = deployment_info.first['cobbler']['profile']
      case os
      when 'centos-x86_64' then 'centos'
      when 'ubuntu_1404_x86_64' then 'ubuntu'
      else
        raise DeploymentEngineError, "Unknown system #{os}"
      end
    end

    def run_shell_command_remotely(context, nodes_uids, cmd)
      response = run_shell_command(context, nodes_uids, cmd)
      response.fetch(:data, {})[:exit_code] == 0
    end

  end #class
end
