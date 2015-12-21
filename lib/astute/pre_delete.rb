#    Copyright 2015 Mirantis, Inc.
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
  module PreDelete

    def self.check_ceph_osds(ctx, nodes)
      answer = {"status" => "ready"}
      ceph_nodes = nodes.select { |n| n["roles"].include? "ceph-osd" }
      ceph_osds = ceph_nodes.collect{ |n| n["slave_name"] }
      return answer if ceph_osds.empty?

      cmd = "ceph -f json osd tree"
      result = {}
      shell = nil

      ceph_nodes.each do |ceph_node|
        shell = MClient.new(ctx, "execute_shell_command", [ceph_node["id"]], timeout=60, retries=1)
        result = shell.execute(:cmd => cmd).first.results
        break if result[:data][:exit_code] == 0
      end

      if result[:data][:exit_code] != 0
        Astute.logger.debug "Ceph has not been found or has not been configured properly" \
          " Safely removing nodes..."
        return answer
      end

      osds = {}

      tree = JSON.parse(result[:data][:stdout])

      tree["nodes"].each do |osd|
        osds[osd["name"]] = osd["children"] if ceph_osds.include? osd["name"]
      end

      # pg dump lists all pgs in the cluster and where they are located.
      # $14 is the 'up set' (the list of OSDs responsible for a particular
      # pg for an epoch) and $16 is the 'acting set' (list of OSDs who
      # are [or were at some point] responsible for a pg). These sets
      # will generally be the same.
      osd_list = osds.values.flatten.join("|")
      cmd = "ceph pg dump 2>/dev/null | " \
            "awk '//{print $14, $16}' | " \
            "egrep -o '\\<(#{osd_list})\\>' | " \
            "sort -un"

      result = shell.execute(:cmd => cmd).first.results
      rs = result[:data][:stdout].split("\n")

      # JSON.parse returns the children as integers, so the result from the
      # shell command needs to be converted for the set operations to work.
      rs.map! { |x| x.to_i }

      error_nodes = []
      osds.each do |name, children|
        error_nodes << name if rs & children != []
      end

      if not error_nodes.empty?
        msg = "Ceph data still exists on: #{error_nodes.join(', ')}. " \
              "You must manually remove the OSDs from the cluster " \
              "and allow Ceph to rebalance before deleting these nodes."
        answer = {"status" => "error", "error" => msg}
      end

      answer
    end

    def self.remove_ceph_mons(ctx, nodes)
      answer = {"status" => "ready"}
      ceph_mon_nodes = nodes.select { |n| n["roles"].include? "controller" }
      ceph_mons = ceph_mon_nodes.collect{ |n| n["slave_name"] }
      return answer if ceph_mon_nodes.empty?

      #Get the list of mon nodes
      result = {}
      shell = nil

      ceph_mon_nodes.each do |ceph_mon_node|
        shell = MClient.new(ctx, "execute_shell_command", [ceph_mon_node["id"]], timeout=120, retries=1)
        result = shell.execute(:cmd => "ceph -f json mon dump").first.results
        break if result[:data][:exit_code] == 0
      end

      if result[:data][:exit_code] != 0
        Astute.logger.debug "Ceph mon has not been found or has not been configured properly" \
          " Safely removing nodes..."
        return answer
      end

      mon_dump = JSON.parse(result[:data][:stdout])
      left_mons = mon_dump['mons'].select { | n | n if ! ceph_mons.include? n['name'] }
      left_mon_names = left_mons.collect { |n| n['name'] }
      left_mon_ips = left_mons.collect { |n| n['addr'].split(":")[0] }

      #Remove nodes from ceph cluster
      Astute.logger.info("Removing ceph mons #{ceph_mons} from cluster")
      ceph_mon_nodes.each do |node|
        shell = MClient.new(ctx, "execute_shell_command", [node["id"]], timeout=120, retries=1)
        #remove node from ceph mon list
        shell.execute(:cmd => "ceph mon remove #{node["slave_name"]}").first.results
      end

      #Fix the ceph.conf on the left mon nodes
      left_mon_names.each do |node|
        mon_initial_members_cmd = "sed -i \"s/mon_initial_members.*/mon_initial_members\ = #{left_mon_names.join(" ")}/g\" /etc/ceph/ceph.conf"
        mon_host_cmd = "sed -i \"s/mon_host.*/mon_host\ = #{left_mon_ips.join(" ")}/g\" /etc/ceph/ceph.conf"
        shell = MClient.new(ctx, "execute_shell_command", [node.split('-')[1]], timeout=120, retries=1)
        shell.execute(:cmd => mon_initial_members_cmd).first.results
        shell.execute(:cmd => mon_host_cmd).first.results
      end

      Astute.logger.info("Ceph mons are left in cluster: #{left_mon_names}")

      answer
    end

    def self.gsub_mongo_out(out)
      out.gsub!(/\/n/, '')
      out.gsub!(/\/t/, '')
      out.gsub!(/ObjectId\(([^)]*)\)/, '\1')
      out.gsub!(/ISODate\((.+?)\)/, '\1 ')
      out.gsub!(/^Error\:.+/, '')
      return out
    end

    def self.remove_mongo_nodes(ctx, nodes)
      answer = {"status" => "ready"}
      mongo_nodes = nodes.select { |n| n["roles"] and (n["roles"].include? "mongo" or n["roles"].include? "primary-mongo") }
      return answer if mongo_nodes.empty?

      # Collect mongo nodes names
      cmd_rs_conf = 'mongo --quiet --eval "load(\'/root/.mongorc.js\'); printjson(rs.conf())"'
      shell = MClient.new(ctx, "execute_shell_command", [mongo_nodes.first["id"]])
      out = gsub_mongo_out(shell.execute(:cmd => cmd_rs_conf).first.results[:data][:stdout])
      out = JSON.parse(out)

      mongo_hosts = []
      out['members'].each do |member|
        mongo_hosts.push(member['host'])
      end

      cmd_shutdown_mongo = 'mongo admin --quiet --eval "load(\'/root/.mongorc.js\'); printjson(db.shutdownServer())"'
      cmd_stepdown_master = 'mongo --quiet --eval "load(\'/root/.mongorc.js\'); printjson(rs.stepDown())"'

      deleted_hosts = []
      # Collect names of mongo nodes to be deleted
      cmd_is_master = 'mongo --quiet --eval "load(\'/root/.mongorc.js\'); printjson(db.isMaster())"'
      mongo_nodes.each do |node|
        shell = MClient.new(ctx, "execute_shell_command", [node["id"]])
        out = gsub_mongo_out(shell.execute(:cmd => cmd_is_master).first.results[:data][:stdout])
        out = JSON.parse(out)
        deleted_hosts.push(out['me'])
        if out['ismaster'].to_s == 'true'
          Astute.logger.debug "Master is going to be deleted: #{out['me']}"
          shell.execute(:cmd => cmd_stepdown_master)
          sleep 10
        end
        shell.execute(:cmd => cmd_shutdown_mongo)
      end
      return answer if deleted_hosts.empty?

      alive_hosts = mongo_hosts - deleted_hosts

      if alive_hosts.length > 0
        retry_count = 10
        n = 0
        primary = false
        while n < retry_count do
          n +=1
          sleep 10

          alive_hosts.each do |host|
            # Wait till one of the left mongo hosts will become primary
            cmd_is_master = "mongo #{host} --quiet --eval \"load('/root/.mongorc.js'); printjson(db.isMaster())\""
            shell = MClient.new(ctx, "execute_shell_command", [mongo_nodes.first["id"]])
            out = gsub_mongo_out(shell.execute(:cmd => cmd_is_master).first.results[:data][:stdout])
            if JSON.parse(out)['ismaster'].to_s == 'true'
            # Get hostname of primary node
              primary = host
              Astute.logger.debug "Primary node: #{primary}"
              break
            end
          end
          if !primary
            Astute.logger.debug "Can't find Mongo replica set master. Retry: #{n}/#{retry_count}"
            if n >= retry_count
              return {"status" => "error", "error" => "Can't find Mongo replica set master"}
            end
          else
            break
          end
        end

        deleted_hosts.each do |deleted|
          # Run mongo client from first mongo node
          shell = MClient.new(ctx, "execute_shell_command", [mongo_nodes.first["id"]])
          cmd = "mongo #{primary} --quiet --eval \"load('/root/.mongorc.js'); printjson(rs.remove('#{deleted}'))\""
          result = shell.execute(:cmd => cmd).first.results
          if result[:data][:exit_code] != 0
            answer = {"status" => "error", "error" => "Can't delete mongo nodes from mongo cluster"}
            break
          end
        end
      end

      return answer
    end

    def self.check_for_offline_nodes(ctx, nodes)
      answer = {"status" => "ready"}
      # FIXME(vsharshov): We send for node/cluster deletion operation
      # as integer instead of String
      mco_nodes = nodes.map { |n| n['uid'].to_s }


      online_nodes = detect_available_nodes(ctx, mco_nodes)
      offline_nodes = mco_nodes - online_nodes

      if offline_nodes.present?
        offline_nodes.map! { |e| {'uid' => e} }
        msg = "MCollective is not running on nodes: " \
              "#{offline_nodes.collect {|n| n['uid'] }.join(',')}. " \
              "MCollective must be running to properly delete a node."
        Astute.logger.warn msg
        answer = {'status' => 'error',
                  'error' => msg,
                  'error_nodes' => offline_nodes}
      end

      answer
    end

    private

    def self.detect_available_nodes(ctx, uids)
      all_uids = uids.clone
      available_uids = []

      # In case of big amount of nodes we should do several calls to be sure
      # about node status
      Astute.config[:mc_retries].times.each do
        systemtype = Astute::MClient.new(ctx, "systemtype", all_uids, check_result=false, 10)
        available_nodes = systemtype.get_type

        available_uids += available_nodes.map { |node| node.results[:sender] }
        all_uids -= available_uids
        break if all_uids.empty?

        sleep Astute.config[:mc_retry_interval]
      end

      available_uids
    end

  end
end
