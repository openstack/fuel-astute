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
  module ProxyReporter
    class TaskProxyReporter

      STATES = ['deploying', 'ready', 'error', 'stopped']
      FINAL_STATES = ['ready', 'error', 'stopped']
      TASK_STATES = ['running', 'successful', 'failed']

      TASK_STATE_TO_STATE_MAP = {
        'running' => 'running',
        'successful' => 'ready',
        'failed' => 'error'
      }

      def initialize(up_reporter, nodes_uids=[])
        @up_reporter = up_reporter
        @nodes = nodes_uids.inject({}) do |nodes, node_uid|
          nodes.merge(node_uid => {'status' => 'pending', 'progress' => nil})
        end
      end

      def report(data)
        if data['nodes']
          nodes_to_report = get_nodes_to_report(data['nodes'])
          return if nodes_to_report.empty? # Let's report only if nodes updated

          update_saved_nodes(nodes_to_report)
          data['nodes'] = nodes_to_report
        end

        @up_reporter.report(data)
      end

      private

      def get_nodes_to_report(nodes)
        nodes.map{ |node| node_validate(node) }.compact
      end

      def node_validate(node)
        return if node_should_exclude?(node)
        validates_node_basic_fields(node)
        if contain_task_info?(node)
          validates_task_basic_fields(node)
          conver_task_status_to_status(node)
        end
        normalization_progress(node)
        compare_with_previous_state(node)
      end

      def node_should_exclude?(node)
        node['uid'].to_i == 0 && node['uid'] != 'master'
      end

      def valid_status?(status)
        STATES.include? status.to_s
      end

      def valid_task_status?(status)
        TASK_STATES.include? status.to_s
      end

      def final_status?(status)
        FINAL_STATES.include? status.to_s
      end

      # Validate of basic fields in message about node
      def validates_node_basic_fields(node)
        err = []

        err << "Status provided '#{node['status']}' is not supported" if
          node['status'] && !valid_status?(node['status'])
        err << "progress value provided, but no status" if
          !node['status'] && node['progress']
        err << "Node uid is not provided" unless node['uid']

        fail_validation(node, err) if err.any?
      end

       # Validate of basic fields in message about task
      def validates_task_basic_fields(node)
        err = []

        err << "Status provided '#{node['task_status']}' is not supported" if
         !valid_task_status?(node['task_status'])
        err << "Task name is not provided" if node['deployment_graph_task_name'].blank?

        fail_validation(node, err) if err.any?
      end


      def conver_task_status_to_status(node)
        node['task_status'] = TASK_STATE_TO_STATE_MAP.fetch(node['task_status'])
      end

      # Normalization of progress field: ensures that the scaling progress was
      # in range from 0 to 100 and has a value of 100 fot the final node
      # status
      def normalization_progress(node)
        if node['progress']
          node['progress'] = 100 if node['progress'] > 100 ||
            ['ready', 'error'].include?(node['status'])
          node['progress'] = 0 if node['progress'] < 0
        else
          node['progress'] = 100 if final_status?(node['status'])
        end
      end

      # Comparison information about node with previous state
      def compare_with_previous_state(node)
        saved_node = @nodes[node['uid']]
        return node unless saved_node

        node_progress = node['progress'] || saved_node['progress'].to_i

        return if final_status?(saved_node['status']) &&
          !final_status?(node['status'])
        # Allow to send only node progress/status update
        return if node_progress.to_i <= saved_node['progress'].to_i &&
          node['status'] == saved_node['status'] &&
          node['deployment_graph_task_name'] == saved_node['deployment_graph_task_name']

        node
      end

      def update_saved_nodes(new_nodes)
        new_nodes.each do |node|
          saved_node = @nodes[node['uid']]
          if saved_node
            node.each {|k, v| saved_node[k] = v}
          else
            @nodes[node['uid']] = node
          end
        end
      end

      def fail_validation(node, err)
        msg = "Validation of node:\n#{node.pretty_inspect} for " \
          "report failed: #{err.join('; ')}"
        Astute.logger.error(msg)
        raise Astute::AstuteError, msg
      end

      def contain_task_info?(node)
        (node.keys & ['task_status', 'deployment_graph_task_name', 'custom']).present?
      end

    end
  end
end