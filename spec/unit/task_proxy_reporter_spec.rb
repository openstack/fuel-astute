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


require File.join(File.dirname(__FILE__), '../spec_helper')

include Astute

describe "TaskProxyReporter" do
  context "Instance of ProxyReporter class" do
    let(:msg) { {'nodes' => [{'status' => 'ready', 'uid' => '1'}]} }
    let(:msg_pr) do
      {'nodes' => [
        msg['nodes'][0],
        {'status' => 'deploying', 'uid' => '2', 'progress' => 54}
      ]}
    end

    let(:up_reporter) { mock('up_reporter') }
    let(:reporter) { ProxyReporter::TaskProxyReporter.new(up_reporter) }

    it "reports first-come data" do
      up_reporter.expects(:report).with(msg)
      reporter.report(msg)
    end

    it "does not report the same message" do
      up_reporter.expects(:report).with(msg).once
      5.times { reporter.report(msg) }
    end

    it "reports only updated node" do
      updated_node = msg_pr['nodes'][1]
      expected_msg = {'nodes' => [updated_node]}
      up_reporter.expects(:report).with(msg)
      up_reporter.expects(:report).with(expected_msg)
      reporter.report(msg)
      reporter.report(msg_pr)
    end

    it "reports only if progress value is greater" do
      msg1 = {'nodes' => [{'status' => 'deploying', 'uid' => '1', 'progress' => 54,
                           'deployment_graph_task_name' => 'test_1', 'task_status' => 'running'},
                          {'status' => 'deploying', 'uid' => '2', 'progress' => 54,
                           'deployment_graph_task_name' => 'test_1', 'task_status' => 'running'}]}
      msg2 = Marshal.load(Marshal.dump(msg1))
      msg2['nodes'][1]['progress'] = 100
      msg2['nodes'][1]['status'] = 'ready'
      updated_node = msg2['nodes'][1]
      expected_msg = {'nodes' => [updated_node]}

      up_reporter.expects(:report).with(msg1)
      up_reporter.expects(:report).with(expected_msg)
      reporter.report(msg1)
      reporter.report(msg2)
    end

    it "reports if progress value same, but deployment graph task name different" do
      msg1 = {'nodes' => [{'status' => 'deploying', 'uid' => '1', 'progress' => 54,
                           'deployment_graph_task_name' => 'test_1', 'task_status' => 'running'}]}
      msg2 = {'nodes' => [{'status' => 'deploying', 'uid' => '1', 'progress' => 54,
                           'deployment_graph_task_name' => 'test_2', 'task_status' => 'running'}]}

      up_reporter.expects(:report).with(msg1)
      up_reporter.expects(:report).with(msg2)
      reporter.report(msg1)
      reporter.report(msg2)
    end

    it "should report only nodes with integer > 0 or master uid" do
      input_msg = {'nodes' => [
        {'uid' => '0', 'status' => 'deploying', 'progress' => 10},
        {'uid' => 'virtual_sync_node', 'status' => 'deploying', 'progress' => 10},
        {'uid' => '1', 'status' => 'deploying', 'progress' => 10}
      ]}

      expected_msg = {'nodes' => [{'uid' => '1', 'status' => 'deploying', 'progress' => 10}]}
      up_reporter.expects(:report).with(expected_msg).once
      reporter.report(input_msg)
    end

    it "raises exception if wrong key passed" do
      msg['nodes'][0]['ups'] = 'some_value'
      lambda {reporter.report(msg)}.should raise_error
    end

    it "adjusts progress to 100 if passed greater" do
      input_msg = {'nodes' => [{'uid' => 1, 'status' => 'deploying', 'progress' => 120}]}
      expected_msg = {'nodes' => [{'uid' => 1, 'status' => 'deploying', 'progress' => 100}]}
      up_reporter.expects(:report).with(expected_msg)
      reporter.report(input_msg)
    end

    it "adjusts progress to 0 if passed less" do
      input_msg = {'nodes' => [{'uid' => 1, 'status' => 'deploying', 'progress' => -20}]}
      expected_msg = {'nodes' => [{'uid' => 1, 'status' => 'deploying', 'progress' => 0}]}
      up_reporter.expects(:report).with(expected_msg)
      reporter.report(input_msg)
    end

    it "adjusts progress to 100 if status ready and no progress given" do
      input_msg = {'nodes' => [{'uid' => 1, 'status' => 'ready'}]}
      expected_msg = {'nodes' => [{'uid' => 1, 'status' => 'ready', 'progress' => 100}]}
      up_reporter.expects(:report).with(expected_msg)
      reporter.report(input_msg)
    end

    it "adjusts progress to 100 if status ready with progress" do
      input_msg = {'nodes' => [{'uid' => 1, 'status' => 'ready', 'progress' => 50}]}
      expected_msg = {'nodes' => [{'uid' => 1, 'status' => 'ready', 'progress' => 100}]}
      up_reporter.expects(:report).with(expected_msg)
      reporter.report(input_msg)
    end

    it "does not report if node was in ready, and trying to set is deploying" do
      msg1 = {'nodes' => [{'uid' => 1, 'status' => 'ready'}]}
      msg2 = {'nodes' => [{'uid' => 2, 'status' => 'ready'}]}
      msg3 = {'nodes' => [{'uid' => 1, 'status' => 'deploying', 'progress' => 100}]}
      up_reporter.expects(:report).with(msg1)
      up_reporter.expects(:report).with(msg2)
      up_reporter.expects(:report).never
      reporter.report(msg1)
      reporter.report(msg2)
      5.times { reporter.report(msg3) }
    end

    it "reports even not all keys provided" do
      msg1 = {'nodes' => [{'uid' => 1, 'status' => 'deploying'}]}
      msg2 = {'nodes' => [{'uid' => 2, 'status' => 'ready'}]}
      up_reporter.expects(:report).with(msg1)
      up_reporter.expects(:report).with(msg2)
      reporter.report(msg1)
      reporter.report(msg2)
    end

    it "raises exception if progress provided and no status" do
      msg1 = {'nodes' => [{'uid' => 1, 'status' => 'ready'}]}
      msg2 = {'nodes' => [{'uid' => 1, 'progress' => 100}]}
      up_reporter.expects(:report).with(msg1)
      up_reporter.expects(:report).never
      reporter.report(msg1)
      lambda {reporter.report(msg2)}.should raise_error
    end

    it "raises exception if status of node is not supported" do
      msg1 = {'nodes' => [{'uid' => 1, 'status' => 'hah'}]}
      up_reporter.expects(:report).never
      lambda {reporter.report(msg1)}.should raise_error
    end

    it "some other attrs are valid and passed" do
      msg1 = {'nodes' => [{'uid' => 1, 'status' => 'deploying'}]}
      msg2 = {'status' => 'error', 'error_type' => 'deploy',
              'nodes' => [{'uid' => 2, 'status' => 'error', 'message' => 'deploy'}]}
      up_reporter.expects(:report).with(msg1)
      up_reporter.expects(:report).with(msg2)
      reporter.report(msg1)
      reporter.report(msg2)
    end

    it "reports if status is greater" do
      msgs = [
        {'nodes' => [{'uid' => 1, 'status' => 'deploying'}]},
        {'nodes' => [{'uid' => 1, 'status' => 'ready'}]},
        {'nodes' => [{'uid' => 1, 'status' => 'deploying'}]},
      ]
      up_reporter.expects(:report).with(msgs[0])
      up_reporter.expects(:report).with(msgs[1])
      msgs.each {|msg| reporter.report(msg)}
    end

    it "report if final status changed" do
      msgs = [
        {'nodes' => [{'uid' => 1, 'status' => 'deploying'}]},
        {'nodes' => [{'uid' => 1, 'status' => 'ready'}]},
        {'nodes' => [{'uid' => 1, 'status' => 'deploying'}]},
        {'nodes' => [{'uid' => 1, 'status' => 'error'}]}
      ]
      up_reporter.expects(:report).with(msgs[0])
      up_reporter.expects(:report).with(msgs[1])
      up_reporter.expects(:report).with(msgs[3])
      msgs.each {|msg| reporter.report(msg)}
    end

    it "doesn't update progress if it less than previous progress with same status" do
      msgs = [
        {'nodes' => [{'uid' => 1, 'status' => 'deploying', 'progress' => 50}]},
        {'nodes' => [{'uid' => 1, 'status' => 'deploying', 'progress' => 10}]}
      ]
      up_reporter.expects(:report).with(msgs[0])
      up_reporter.expects(:report).never
      msgs.each {|msg| reporter.report(msg)}
    end

    it "doesn't forget previously reported attributes" do
      msgs = [{'nodes' => [{'uid' => 1, 'status' => 'deploying', 'progress' => 50}]},
              {'nodes' => [{'uid' => 1, 'status' => 'deploying'}]},
              {'nodes' => [{'uid' => 1, 'status' => 'deploying', 'key' => 'value', 'progress' => 60}]},
              {'nodes' => [{'uid' => 1, 'status' => 'deploying', 'progress' => 0}]},
            ]
      up_reporter.expects(:report).with(msgs[0])
      up_reporter.expects(:report).with(msgs[2])
      up_reporter.expects(:report).never
      msgs.each {|msg| reporter.report(msg)}
    end

    it "report stopped status" do
      msgs = [
        {'nodes' => [{'uid' => 1, 'status' => 'deploying'}]},
        {'nodes' => [{'uid' => 1, 'status' => 'stopped'}]},
      ]
      up_reporter.expects(:report).with(msgs[0])
      up_reporter.expects(:report).with(msgs[1])
      msgs.each {|msg| reporter.report(msg)}
    end


    context 'tasks' do
      let(:msg) do
        {'nodes' => [{'status' => 'deploying', 'uid' => '1', 'progress' => 54}.merge(task_part_msg)]
        }
      end

      let(:task_part_msg) do
        {'deployment_graph_task_name' => 'test_1', 'task_status' => 'running'}
      end

      context 'validation' do
        it 'should not validate if no task fields present' do
          node_report_msg = {'nodes' => [{'uid' => 1, 'status' => 'deploying'}]}
          up_reporter.expects(:report).with(node_report_msg)
          reporter.report(node_report_msg)
        end

        it 'should validate deployment graph task name' do
          msg['nodes'].first.delete('deployment_graph_task_name')
          up_reporter.expects(:report).never
          expect { reporter.report(msg) }.to raise_error(
            Astute::AstuteError,
            /Task name is not provided/
          )
        end

        it 'should validate task status absent' do
          msg['nodes'].first.delete('task_status')
          up_reporter.expects(:report).never
          expect { reporter.report(msg) }.to raise_error(
            Astute::AstuteError,
            /Status provided '' is not supported/
          )
        end
      end

      context 'task status convertation' do
        it 'should convert task running status to running' do
          up_reporter.expects(:report).with(msg)
          reporter.report(msg)
        end

        it 'should convert task failed status to error' do
          task_part_msg['task_status'] = 'failed'
          expected_msg = msg.deep_dup
          expected_msg['nodes'].first['task_status'] = 'error'
          up_reporter.expects(:report).with(expected_msg)
          reporter.report(msg)
        end

        it 'should convert task successful status to ready' do
          task_part_msg['task_status'] = 'successful'
          expected_msg = msg.deep_dup
          expected_msg['nodes'].first['task_status'] = 'ready'
          up_reporter.expects(:report).with(expected_msg)
          reporter.report(msg)
        end

        it 'should failed if task has inccorect status' do
          task_part_msg['task_status'] = 'unknown'
          up_reporter.expects(:report).never
          expect { reporter.report(msg) }.to raise_error(
            Astute::AstuteError,
            /Status provided 'unknown' is not supported/
          )
        end
      end
    end

  end
end
