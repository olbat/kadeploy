#!/usr/bin/ruby -w

# Kadeploy 3.0
# Copyright (c) by INRIA, Emmanuel Jeanvoine - 2008, 2009
# CECILL License V2 - http://www.cecill.info
# For details on use and redistribution please refer to License.txt

#Kadeploy libs
require 'managers'
require 'debug'
require 'microsteps'
require 'process_management'

#Ruby libs
require 'drb'
require 'socket'
require 'yaml'
require 'digest/sha1'

class KadeployServer
  @config = nil
  @client = nil
  attr_reader :deployments_table_lock
  attr_reader :tcp_buffer_size
  attr_reader :dest_host
  attr_reader :dest_port
  @reboot_window = nil
  @nodes_check_window = nil
  @syslog_lock = nil
  @workflow_hash = nil
  @workflow_hash_lock = nil
  @workflow_hash_index = nil
  
  public
  # Constructor of KadeployServer
  #
  # Arguments
  # * config: instance of Config
  # * reboot_window: instance of WindowManager to manage the reboot window
  # * nodes_check_window: instance of WindowManager to manage the check of the nodes
  # Output
  # * raises an exception if the file server can not open a socket
  def initialize(config, reboot_window, nodes_check_window)
    @config = config
    @dest_host = @config.common.kadeploy_server
    @tcp_buffer_size = @config.common.kadeploy_tcp_buffer_size
    @reboot_window = reboot_window
    @nodes_check_window = nodes_check_window
    @deployments_table_lock = Mutex.new
    @syslog_lock = Mutex.new
    @workflow_info_hash = Hash.new
    @workflow_info_hash_lock = Mutex.new
    @reboot_info_hash = Hash.new
    @reboot_info_hash_lock = Mutex.new
  end

  # Give the current version of Kadeploy (RPC)
  #
  # Arguments
  # * nothing
  # Output
  # * nothing
  def get_version
    return @config.common.version
  end

  def get_bootloader
    return @config.common.bootloader
  end


  def run(kind, exec_specific_config, host, port)
    db = Database::DbFactory.create(@config.common.db_kind)
    if not db.connect(@config.common.deploy_db_host,
                      @config.common.deploy_db_login,
                      @config.common.deploy_db_passwd,
                      @config.common.deploy_db_name) then
      puts "Kadeploy server cannot connect to DB"
      return false
    end
    if ((host == nil) || (port == nil)) then
      client = nil
    else
      DRb.start_service("druby://localhost:0")
      uri = "druby://#{host}:#{port}"
      client = DRbObject.new(nil, uri)
    end
    res = @config.check_client_config(kind, exec_specific_config, db, client)
    case kind
    when "kadeploy_sync"
      res = res && run_kadeploy_sync(db, client, exec_specific_config)
    when "kadeploy_async"
      res = res && run_kadeploy_async(db, exec_specific_config)
    when "kareboot"
      res = res && run_kareboot(db, client, exec_specific_config)
    when "kastat"
      res = res && run_kastat(db, client, exec_specific_config)
    when "kanodes"
      res = res && run_kanodes(db, client, exec_specific_config)
    when "karights"
      res = res && run_karights(db, client, exec_specific_config)
    when "kaenv"
      res = res && run_kaenv(db, client, exec_specific_config)
    when "kaconsole"
      res = res && run_kaconsole(db, client, exec_specific_config)
    end

    db.disconnect
    client = nil
    exec_specific = nil
    DRb.stop_service()
    GC.start

    return res
  end


  ##################################
  #      Public Kadeploy Sync      #
  ##################################

  # Launch the Kadeploy workflow from the client side (RPC)
  #
  # Arguments
  # * db: database handler
  # * client: DRb handler of the Kadeploy client
  # * exec_specific: instance of Config.exec_specific
  # Output
  # * return false if cannot connect to DB, true otherwise
  def run_kadeploy_sync(db, client, exec_specific)
    #We create a new instance of Config with a specific exec_specific part
    config = ConfigInformation::Config.new(true)
    config.common = @config.common
    config.exec_specific = exec_specific
    config.cluster_specific = Hash.new
    
    #Overide the configuration if the steps are specified in the command line
    if (not exec_specific.steps.empty?) then
      exec_specific.node_set.group_by_cluster.each_key { |cluster|
        config.cluster_specific[cluster] = ConfigInformation::ClusterSpecificConfig.new
        @config.cluster_specific[cluster].duplicate_but_steps(config.cluster_specific[cluster], exec_specific.steps)
      }
      #If the environment specifies a preinstall, we override the automata to use specific preinstall
    elsif (exec_specific.environment.preinstall != nil) then
      Debug::distant_client_error("A specific presinstall will be used with this environment", client)
      exec_specific.node_set.group_by_cluster.each_key { |cluster|
        config.cluster_specific[cluster] = ConfigInformation::ClusterSpecificConfig.new
        @config.cluster_specific[cluster].duplicate_all(config.cluster_specific[cluster])
        instance = config.cluster_specific[cluster].get_macro_step("SetDeploymentEnv").get_instance
        max_retries = instance[1]
        timeout = instance[2]
        config.cluster_specific[cluster].replace_macro_step("SetDeploymentEnv", ["SetDeploymentEnvUntrustedCustomPreInstall", max_retries, timeout])
      }
    else
      exec_specific.node_set.group_by_cluster.each_key { |cluster|
        config.cluster_specific[cluster] = ConfigInformation::ClusterSpecificConfig.new
        @config.cluster_specific[cluster].duplicate_all(config.cluster_specific[cluster])
      }
    end
    @workflow_info_hash_lock.lock
    workflow_id = Digest::SHA1.hexdigest(config.exec_specific.true_user + Time.now.to_s + exec_specific.node_set.to_s)
    workflow = Managers::WorkflowManager.new(config, client, @reboot_window, @nodes_check_window, db, @deployments_table_lock, @syslog_lock, workflow_id)
    kadeploy_add_workflow_info(workflow, workflow_id)
    @workflow_info_hash_lock.unlock
    client.set_workflow_id(workflow_id)
    client.write_workflow_id(exec_specific.write_workflow_id) if exec_specific.write_workflow_id != ""
    finished = false
    tid = Thread.new {
      while (not finished) do
        begin
          client.test()
        rescue DRb::DRbConnError
          workflow.output.disable_client_output()
          workflow.output.verbosel(3, "Client disconnection")
          workflow.kill()
          finished = true
        end
        sleep(1)
      end
    }
    if (workflow.prepare() && workflow.manage_files(false)) then
      workflow.run_sync()
    else
      workflow.output.verbosel(0, "Cannot run the deployment")
    end
    finished = true
    #let's free memory at the end of the workflow
    tid = nil
    @workflow_info_hash_lock.lock
    kadeploy_delete_workflow_info(workflow_id)
    @workflow_info_hash_lock.unlock
    workflow.finalize
    workflow = nil
    config = nil
    return true
  end

  # Create a socket server designed to copy a file from to client to the server cache (RPC)
  #
  # Arguments
  # * filename: name of the destination file
  # Output
  # * return the port allocated to the socket server
  def kadeploy_sync_create_a_socket_server(filename)
    sock = Socket.new(Socket::AF_INET, Socket::SOCK_STREAM, 0)
    sockaddr = Socket.pack_sockaddr_in(0, @config.common.kadeploy_server)
    begin
      sock.bind(sockaddr)
    rescue
      return -1
    end
    port = Socket.unpack_sockaddr_in(sock.getsockname)[0].to_i
    Thread.new {
      sock.listen(10)
      begin
        session = sock.accept
        file = File.new(@config.common.kadeploy_cache_dir + "/" + filename, "w")
        while ((buf = session[0].recv(@tcp_buffer_size)) != "") do
          file.write(buf)
        end
        file.close
        session[0].close
      rescue
        puts "The client has been probably disconnected..."
      end
    }
    return port
  end

  # Kill a workflow (RPC)
  #
  # Arguments
  # * workflow_id: id of the workflow
  # Output
  # * nothing  
  def kadeploy_sync_kill_workflow(workflow_id)
    # id == -1 means that the workflow has not been launched yet
    @workflow_info_hash_lock.synchronize {
      if ((workflow_id != -1) && (@workflow_info_hash.has_key?(workflow_id))) then
        workflow = @workflow_info_hash[workflow_id]
        workflow.kill()
        kadeploy_delete_workflow_info(workflow_id)
      end
    }
  end

  ##################################
  #    Public Kadeploy Async       #
  ##################################

  # Launch the workflow in an asynchronous way (RPC)
  #
  # Arguments
  # * db: database handler
  # * exec_specific: instance of Config.exec_specific
  # Output
  # * return a workflow id(, or nil if all the nodes have been discarded) and an integer (0: no error, 1: nodes discarded, 2: some files cannot be grabbed, 3: server cannot connect to DB)
  def run_kadeploy_async(db, exec_specific)
    #We create a new instance of Config with a specific exec_specific part
    config = ConfigInformation::Config.new("empty")
    config.common = @config.common
    config.exec_specific = exec_specific
    config.cluster_specific = Hash.new

    #Overide the configuration if the steps are specified in the command line
    if (not exec_specific.steps.empty?) then
      exec_specific.node_set.group_by_cluster.each_key { |cluster|
        config.cluster_specific[cluster] = ConfigInformation::ClusterSpecificConfig.new
        @config.cluster_specific[cluster].duplicate_but_steps(config.cluster_specific[cluster], exec_specific.steps)
      }
      #If the environment specifies a preinstall, we override the automata to use specific preinstall
    elsif (exec_specific.environment.preinstall != nil) then
      exec_specific.node_set.group_by_cluster.each_key { |cluster|
        config.cluster_specific[cluster] = ConfigInformation::ClusterSpecificConfig.new
        @config.cluster_specific[cluster].duplicate_all(config.cluster_specific[cluster])
        instance = config.cluster_specific[cluster].get_macro_step("SetDeploymentEnv").get_instance
        max_retries = instance[1]
        timeout = instance[2]
        config.cluster_specific[cluster].replace_macro_step("SetDeploymentEnv", ["SetDeploymentEnvUntrustedCustomPreInstall", max_retries, timeout])
      }
    else
      exec_specific.node_set.group_by_cluster.each_key { |cluster|
        config.cluster_specific[cluster] = ConfigInformation::ClusterSpecificConfig.new
        @config.cluster_specific[cluster].duplicate_all(config.cluster_specific[cluster])
      }
    end
    @workflow_info_hash_lock.lock
    workflow_id = Digest::SHA1.hexdigest(config.exec_specific.true_user + Time.now.to_s + exec_specific.node_set.to_s)
    workflow = Managers::WorkflowManager.new(config, nil, @reboot_window, @nodes_check_window, db, @deployments_table_lock, @syslog_lock, workflow_id)
    kadeploy.add_workflow_info(workflow, workflow_id)
    @workflow_info_hash_lock.unlock
    if workflow.prepare() then
      if workflow.manage_files(true) then
        workflow.run_async()
        return workflow_id, 0
      else
        free(workflow_id)
        return nil, 2 # some files cannot be grabbed
      end
    else
      free(workflow_id)
      return nil, 1 # all the nodes are involved in another deployment
    end
  end

  # Test if the workflow has reached the end (RPC: only for async execution)
  #
  # Arguments
  # * workflow_id: worklfow id
  # Output
  # * return true if the workflow has reached the end, false if not, and nil if the workflow does not exist
  def kadeploy_async_ended?(workflow_id)
    @workflow_info_hash_lock.lock
    if @workflow_info_hash.has_key?(workflow_id) then
      workflow = @workflow_info_hash[workflow_id]
      ret = workflow.ended?
    else
      ret = nil
    end
    @workflow_info_hash_lock.unlock
    return ret
  end

  # Get the results of a workflow (RPC: only for async execution)
  #
  # Arguments
  # * workflow_id: worklfow id
  # Output
  # * return a hastable containing the state of all the nodes involved in the deployment or nil if the workflow does not exist
  def kadeploy_async_get_results(workflow_id)
    @workflow_info_hash_lock.lock
    if @workflow_info_hash.has_key?(workflow_id) then
      workflow = @workflow_info_hash[workflow_id]
      ret = workflow.get_results
    else
      ret = nil
    end
    @workflow_info_hash_lock.unlock
    return ret
  end

  # Clean the stuff related to the deployment (RPC: only for async execution)
  #
  # Arguments
  # * id: worklfow id
  # Output
  # * nothing
  def kadeploy_async_free(workflow_id)
    @workflow_info_hash_lock.lock
    if @workflow_info_hash.has_key?(workflow_id) then
      workflow = @workflow_info_hash[workflow_id]
      workflow.db.disconnect
      kadeploy_delete_workflow_info(workflow_id)
      #let's free memory at the end of the workflow
      tid = nil
      workflow.finalize
      workflow = nil
      exec_specific = nil
      GC.start
      ret = true
    else
      ret = nil
    end
    @workflow_info_hash_lock.unlock
    return ret
  end


  ##################################
  #       Public Kareboot          #
  ##################################

  # Reboot a set of nodes from the client side (RPC)
  #
  # Arguments
  # * db: database handler
  # * client: DRb client handler
  # * exec_specific: instance of Config.exec_specific
  # Output
  # * return 0 in case of success, 1 if the reboot failed on some nodes, 2 if the reboot has not been launched, 3 if some pxe files cannot be grabbed
  def run_kareboot(db, client, exec_specific)
    ret = 0
    if (exec_specific.verbose_level != "") then
      vl = exec_specific.verbose_level
    else
      vl = @config.common.verbose_level
    end
    @config.common.taktuk_connector = @config.common.taktuk_ssh_connector
    output = Debug::OutputControl.new(vl, false, client, exec_specific.true_user, -1, 
                                      @config.common.dbg_to_syslog, @config.common.dbg_to_syslog_level, @syslog_lock)
    if (exec_specific.reboot_kind == "env_recorded") && 
        exec_specific.check_prod_env && 
        exec_specific.node_set.check_demolishing_env(db, @config.common.demolishing_env_threshold) then
      output.verbosel(0, "Reboot not performed since some nodes have been deployed with a demolishing environment")
      return 2
    else
      #We create a new instance of Config with a specific exec_specific part
      config = ConfigInformation::Config.new("empty")
      config.common = @config.common.clone
      config.cluster_specific = @config.cluster_specific.clone
      config.exec_specific = exec_specific
      nodes_ok = Nodes::NodeSet.new
      nodes_ko = Nodes::NodeSet.new
      global_nodes_mutex = Mutex.new
      tid_array = Array.new

      if ((exec_specific.reboot_kind == "set_pxe") && (not exec_specific.pxe_upload_files.empty?)) then
        gfm = Managers::GrabFileManager.new(config, output, client, db)
        exec_specific.pxe_upload_files.each { |pxe_file|
          user_prefix = "pxe-#{config.exec_specific.true_user}-"
          tftp_images_path = "#{config.common.tftp_repository}/#{config.common.tftp_images_path}"
          local_pxe_file = "#{tftp_images_path}/#{user_prefix}#{File.basename(pxe_file)}"
          if not gfm.grab_file_without_caching(pxe_file, local_pxe_file, "pxe_file", user_prefix,
                                               tftp_images_path, config.common.tftp_images_max_size, false) then
            output.verbosel(0, "Reboot not performed since some pxe files cannot be grabbed")
            return 3
          end
        }
      end

      exec_specific.node_set.group_by_cluster.each_pair { |cluster, set|
        tid_array << Thread.new {
          step = MicroStepsLibrary::MicroSteps.new(set, Nodes::NodeSet.new, @reboot_window, @nodes_check_window, config, cluster, output, "Kareboot")
          case exec_specific.reboot_kind
          when "env_recorded"
            #This should be the same case than a deployed env
            step.switch_pxe("deploy_to_deployed_env")
          when "set_pxe"
            step.switch_pxe("set_pxe", exec_specific.pxe_profile_msg)
          when "simple_reboot"
            #no need to change the PXE profile
          when "deploy_env"
            step.switch_pxe("prod_to_deploy_env")
          else
            raise "Invalid kind of reboot: #{@reboot_kind}"
          end
          step.reboot(exec_specific.reboot_level, false, true)
          if exec_specific.wait then
            if (exec_specific.reboot_kind == "deploy_env") then
              step.wait_reboot([@config.common.ssh_port,@config.common.test_deploy_env_port],[])
              step.send_key_in_deploy_env("tree")
              set.set_deployment_state("deploy_env", nil, db, exec_specific.true_user)
            else
              step.wait_reboot([@config.common.ssh_port],[])
            end
            if (exec_specific.reboot_kind == "env_recorded") then
              part = String.new
              if (exec_specific.block_device == "") then
                part = get_block_device(cluster) + exec_specific.deploy_part
              else
                part = exec_specific.block_device + exec_specific.deploy_part
              end
              #Reboot on the production environment
              if (part == get_prod_part(cluster)) then
                step.check_nodes("prod_env_booted")
                set.set_deployment_state("prod_env", nil, db, exec_specific.true_user)
                if (exec_specific.check_prod_env) then
                  step.nodes_ko.tag_demolishing_env(db) if config.common.demolishing_env_auto_tag
                  ret = 1
                end
              else
                set.set_deployment_state("recorded_env", nil, db, exec_specific.true_user)
              end
            end
            if not step.nodes_ok.empty? then
              output.verbosel(0, "Nodes correctly rebooted on cluster #{cluster}:")
              output.verbosel(0, step.nodes_ok.to_s(false, "\n"))
              global_nodes_mutex.synchronize {
                nodes_ok.add(step.nodes_ok)
              }
            end
            if not step.nodes_ko.empty? then
              output.verbosel(0, "Nodes not correctly rebooted on cluster #{cluster}:")
              output.verbosel(0, step.nodes_ko.to_s(true, "\n"))
              global_nodes_mutex.synchronize {
                nodes_ko.add(step.nodes_ko)
              }
            end
          end
        }
      }
      tid_array.each { |tid|
        kareboot_add_reboot_info(tid, exec_specific.reboot_id)
      }
      tid_array.each { |tid|
        tid.join
      }
      if exec_specific.wait then
        client.generate_files(nodes_ok, config.exec_specific.nodes_ok_file, nodes_ko, config.exec_specific.nodes_ko_file)
      end
    end
    kareboot_delete_reboot_info(exec_specific.reboot_id)
    config = nil
    return ret
  end

  def kareboot_kill_reboot(reboot_id)
    @reboot_info_hash_lock.synchronize {
      if @reboot_info_hash.has_key?(reboot_id) then
        @reboot_info_hash[reboot_id].each { |tid|
          Thread.kill(tid)
        }
        @reboot_info_hash[reboot_id] = nil
        @reboot_info_hash.delete(reboot_id)
      end
    }
  end


  ##################################
  #        Public Kastat           #
  ##################################
  
  def run_kastat(db, client, exec_specific)
    case exec_specific.operation
    when "list_all"
      return kastat_list_all(exec_specific, client, db)
    when "list_retries"
      return kastat_list_retries(exec_specific, client, db)
    when "list_failure_rate"
      return kastat_list_failure_rate(exec_specific, client, db)
    when "list_min_failure_rate"
      return kastat_list_failure_rate(exec_specific, client, db)
    end
  end


  ##################################
  #        Public Kanodes          #
  ##################################

  def run_kanodes(db, client, exec_specific)
    case exec_specific.operation
    when "get_deploy_state"
      return kanodes_get_deploy_state(exec_specific, client, db)
    when "get_yaml_dump"
      return kanodes_get_yaml_dump(exec_specific, db)
    end
  end
  

  ##################################
  #       Public Karights          #
  ##################################

  def run_karights(db, client, exec_specific)
    case exec_specific.operation  
    when "add"
      karights_add_rights(exec_specific, client, db)
    when "delete"
      karights_delete_rights(exec_specific, client, db)
    when "show"
      karights_show_rights(exec_specific, client, db)
    end
  end


  ##################################
  #        Public Kaenv            #
  ##################################

  def run_kaenv(db, client, exec_specific)
    case exec_specific.operation
    when "list"
      kaenv_list_environments(exec_specific, client, db)
    when "add"
      kaenv_add_environment(exec_specific, client, db)
    when "delete"
      kaenv_delete_environment(exec_specific, client, db)
    when "print"
      kaenv_print_environment(exec_specific, client, db)
    when "update-tarball-md5"
      kaenv_update_tarball_md5(exec_specific, client, db)
    when "update-preinstall-md5"
      kaenv_update_preinstall_md5(exec_specific, client, db)
    when "update-postinstalls-md5"
      kaenv_update_postinstall_md5(exec_specific, client, db)
    when "remove-demolishing-tag"
      kaenv_remove_demolishing_tag(exec_specific, client, db)
    when "set-visibility-tag"
      kaenv_set_visibility_tag(exec_specific, client, db)
    when "move-files"
      kaenv_move_files(exec_specific, client, db)
    end
  end


  ##################################
  #       Public Kaconsole         #
  ##################################
  
  def run_kaconsole(db, client, exec_specific)
  end








  private
  ##################################
  #   Private Kadeploy Sync/Async  #
  ##################################

  # Record a Managers::WorkflowManager pointer
  #
  # Arguments
  # * workflow_ptr: reference toward a Managers::WorkflowManager
  # * workflow_id: workflow_id
  # Output
  # * nothing
  def kadeploy_add_workflow_info(workflow_ptr, workflow_id)
    @workflow_info_hash[workflow_id] = workflow_ptr
  end

  # Delete the information of a workflow
  #
  # Arguments
  # * workflow_id: workflow id
  # Output
  # * nothing
  def kadeploy_delete_workflow_info(workflow_id)
    @workflow_info_hash.delete(workflow_id)
  end


  ##################################
  #       Private Kareboot         #
  ##################################

  def kareboot_add_reboot_info(tid, reboot_id)
    @reboot_info_hash_lock.synchronize {
      if not @reboot_info_hash.has_key?(reboot_id) then
        @reboot_info_hash[reboot_id] = Array.new
      end
      @reboot_info_hash[reboot_id].push(tid)
    }
  end

  def kareboot_delete_reboot_info(reboot_id)
    @reboot_info_hash_lock.synchronize {
      @reboot_info_hash[reboot_id] = nil
      @reboot_info_hash.delete(reboot_id)
    }
  end


  ##################################
  #       Private Kastat           #
  ##################################
  # Generate some filters for the output according the options
  #
  # Arguments
  # * config: instance of Config
  # Output
  # * return a string that contains the where clause corresponding to the filters required
  def kastat_append_generic_where_clause(exec_specific)
    generic_where_clause = String.new
    node_list = String.new
    hosts = Array.new
    date_min = String.new
    date_max = String.new
    if (not exec_specific.node_list.empty?) then
      exec_specific.node_list.each { |node|
        if /\A[A-Za-z\.\-]+[0-9]*\[[\d{1,3}\-,\d{1,3}]+\][A-Za-z0-9\.\-]*\Z/ =~ node then
          nodes = Nodes::NodeSet::nodes_list_expand("#{node}")
        else
          nodes = [node]
        end     
        nodes.each{ |n|
          hosts.push("hostname=\"#{n}\"")
        }
      }
      node_list = "(#{hosts.join(" OR ")})"
    end
    if (exec_specific.date_min != 0) then
      date_min = "start>=\"#{exec_specific.date_min}\""
    end
    if (exec_specific.date_max != 0) then
      date_max = "start<=\"#{exec_specific.date_max}\""
    end
    if ((node_list != "") || (date_min != "") || (date_max !="")) then
      generic_where_clause = "#{node_list} AND #{date_min} AND #{date_max}"
      #let's clean empty things
      generic_where_clause = generic_where_clause.gsub("AND  AND","")
      generic_where_clause = generic_where_clause.gsub(/^ AND/,"")
      generic_where_clause = generic_where_clause.gsub(/AND $/,"")
    end
    return generic_where_clause
  end


  # Select the fields to output
  #
  # Arguments
  # * row: hashtable that contains a line of information fetched in the database
  # * config: instance of Config
  # * default_fields: array of fields used to produce the output if no fields are given in the command line
  # Output
  # * string that contains the selected fields in a result line
  def kastat_select_fields(row, exec_specific, default_fields)
    fields = Array.new  
    if (not exec_specific.fields.empty?) then
      exec_specific.fields.each{ |f|
        fields.push(row[f].gsub("\n", "\\n"))
      }
    else
      default_fields.each { |f|
        fields.push(row[f].gsub("\n", "\\n"))
      }
    end
    return fields.join(",")
  end

  # List the information about the nodes that require a given number of retries to be deployed
  #
  # Arguments
  # * config: instance of Config
  # * db: database handler
  # Output
  # * print the filtred information about the nodes that require a given number of retries to be deployed
  def kastat_list_retries(exec_specific, client, db)
    step_list = String.new
    steps = Array.new
    if (not exec_specific.steps.empty?) then
      exec_specific.steps.each { |step|
        case step
        when "1"
          steps.push("retry_step1>=\"#{exec_specific.min_retries}\"")
        when "2"
          steps.push("retry_step2>=\"#{exec_specific.min_retries}\"")
        when "3"
          steps.push("retry_step3>=\"#{exec_specific.min_retries}\"")
        end
      }
      step_list = steps.join(" AND ")
    else
      step_list += "(retry_step1>=\"#{exec_specific.min_retries}\""
      step_list += " OR retry_step2>=\"#{exec_specific.min_retries}\""
      step_list += " OR retry_step3>=\"#{exec_specific.min_retries}\")"
    end

    generic_where_clause = kastat_append_generic_where_clause(exec_specific)
    if (generic_where_clause == "") then
      query = "SELECT * FROM log WHERE #{step_list}"
    else
      query = "SELECT * FROM log WHERE #{generic_where_clause} AND #{step_list}"
    end
    res = db.run_query(query)
    if (res.num_rows > 0) then
      res.each_hash { |row|
        Debug::distant_client_print(kastat_select_fields(row, exec_specific, ["start","hostname","retry_step1","retry_step2","retry_step3"]), client)
      }
    else
      Debug::distant_client_print("No information is available", client)
    end
  end


  # List the information about the nodes that have at least a given failure rate
  #
  # Arguments
  # * config: instance of Config
  # * db: database handler
  # * min(opt): minimum failure rate
  # Output
  # * print the filtred information about the nodes that have at least a given failure rate
  def kastat_list_failure_rate(exec_specific, client, db)
    generic_where_clause = kastat_append_generic_where_clause(exec_specific)
    if (generic_where_clause != "") then
      query = "SELECT * FROM log WHERE #{generic_where_clause}"
    else
      query = "SELECT * FROM log"
    end
    res = db.run_query(query)
    if (res.num_rows > 0) then
      hash = Hash.new
      res.each_hash { |row|
        if (not hash.has_key?(row["hostname"])) then
          hash[row["hostname"]] = Array.new
        end
        hash[row["hostname"]].push(row["success"])
      }
      hash.each_pair { |hostname, array|
        success = 0
        array.each { |val|
          if (val == "true") then
            success += 1
          end
        }
        rate = 100 - (100 * success / array.length)
        if ((exec_specific.min_rate == nil) || (rate >= exec_specific.min_rate)) then
          Debug::distant_client_print("#{hostname}: #{rate}%", client)
        end
      }
    else
      Debug::distant_client_print("No information is available", client)
    end
  end

  # List the information about all the nodes
  #
  # Arguments
  # * config: instance of Config
  # * db: database handler
  # Output
  # * print the information about all the nodes
  def kastat_list_all(exec_specific, client, db)
    generic_where_clause = kastat_append_generic_where_clause(exec_specific)
    if (generic_where_clause != "") then
      query = "SELECT * FROM log WHERE #{generic_where_clause}"
    else
      query = "SELECT * FROM log"
    end
    res = db.run_query(query)
    if (res.num_rows > 0) then
      res.each_hash { |row|
        Debug::distant_client_print(kastat_select_fields(row, exec_specific,
                                                         ["user","hostname","step1","step2","step3",
                                                          "timeout_step1","timeout_step2","timeout_step3",
                                                          "retry_step1","retry_step2","retry_step3",
                                                          "start",
                                                          "step1_duration","step2_duration","step3_duration",
                                                          "env","anonymous_env","md5",
                                                          "success","error"]),
                                    client)
      }
    else
      Debug::distant_client_print("No information is available", client)
    end
  end

  ##################################
  #       Private Kanodes          #
  ##################################


  # List the deploy information about the nodes
  #
  # Arguments
  # * config: instance of Config
  # * db: database handler
  # Output
  # * prints the information about the nodes in a CSV format
  def kanodes_get_deploy_state(exec_specific, client, db)
    #If no node list is given, we print everything
    if exec_specific.node_list.empty? then
      query = "SELECT nodes.hostname, nodes.state, nodes.user, environments.name, environments.version, environments.user \
             FROM nodes \
             LEFT JOIN environments ON nodes.env_id = environments.id \
             ORDER BY nodes.hostname"
    else
      hosts = Array.new
      exec_specific.node_set.each { |node|
        if /\A[A-Za-z\.\-]+[0-9]*\[[\d{1,3}\-,\d{1,3}]+\][A-Za-z0-9\.\-]*\Z/ =~ node then
          nodes = Nodes::NodeSet::nodes_list_expand("#{node}")
        else
          nodes = [node]
        end
        nodes.each { |n|
          hosts.push("nodes.hostname=\"#{n}\"")
        }
      }
      query = "SELECT nodes.hostname, nodes.state, nodes.user, environments.name, environments.version, environments.user \
             FROM nodes \
             LEFT JOIN environments ON nodes.env_id = environments.id \
             WHERE (#{hosts.join(" OR ")}) \
             ORDER BY nodes.hostname"
    end
    res = db.run_query(query)
    if (res.num_rows > 0)
      res.each { |row|
        Debug::distant_client_print("#{row[0]},#{row[1]},#{row[2]},#{row[3]},#{row[4]},#{row[5]}", client)
      }
    else
      Debug::distant_client_print("No information concerning these nodes", client)
      return(1)
    end
    return(0)
  end

  # Get a YAML output of the current deployments
  #
  # Arguments
  # * kadeploy_server: pointer to the Kadeploy server (DRbObject)
  # * wid: workflow id
  # Output
  # * prints the YAML output of the current deployments
  def kanodes_get_yaml_dump(exec_specific, client)
    Debug::distant_client_print(kanodes_get_workflow_state(exec_specific.wid), client)
    return(0)
  end

  # Get a YAML output of the workflows (RPC)
  #
  # Arguments
  # * workflow_id (opt): workflow id
  # Output
  # * return a string containing the YAML output
  def kanodes_get_workflow_state(workflow_id = "")
    str = String.new
    @workflow_info_hash_lock.lock
    if (@workflow_info_hash.has_key?(workflow_id)) then
      hash = Hash.new
      hash[workflow_id] = @workflow_info_hash[workflow_id].get_state
      str = hash.to_yaml
      hash = nil
    elsif (workflow_id == "") then
      hash = Hash.new
      @workflow_info_hash.each_pair { |key,workflow_info_hash|
        hash[key] = workflow_info_hash.get_state
      }
      str = hash.to_yaml
      hash = nil
    end
    @workflow_info_hash_lock.unlock
    return str
  end

  ##################################
  #       Private Karights         #
  ##################################

  # Show the rights of a user defined in exec_specific.user
  #
  # Arguments
  # * config: instance of Config
  # * db: database handler
  # Output
  # * prints the rights of a specific user
  def karights_show_rights(exec_specific, client, db)
    hash = Hash.new
    query = "SELECT * FROM rights WHERE user=\"#{exec_specific.user}\""
    res = db.run_query(query)
    if res != nil then
      res.each_hash { |row|
        if (not hash.has_key?(row["node"])) then
          hash[row["node"]] = Array.new
        end
        hash[row["node"]].push(row["part"])
      }
      if (res.num_rows > 0) then
        Debug::distant_client_print("The user #{exec_specific.user} has the deployment rights on the following nodes:", client)
        hash.each_pair { |node, part_list|
          Debug::distant_client_print("### #{node}: #{part_list.join(", ")}", client)
        }
      else
        Debug::distant_client_print("No rights have been given for the user #{exec_specific.user}", client)
      end
    end
  end

  # Add some rights on the nodes defined in exec_specific.node_list
  # and on the parts defined in exec_specific.part_list to a specific
  # user defined in exec_specific.user
  #
  # Arguments
  # * config: instance of Config
  # * db: database handler
  # Output
  # * nothing
  def karights_add_rights(exec_specific, client, db)
    #check if other users have rights on some nodes
    nodes_to_remove = Array.new
    hosts = Array.new
    exec_specific.node_list.each { |node|
      if /\A[A-Za-z\.\-]+[0-9]*\[[\d{1,3}\-,\d{1,3}]+\][A-Za-z0-9\.\-]*\Z/ =~ node
        nodes = Nodes::NodeSet::nodes_list_expand("#{node}")
      else
        nodes = [node]
      end
      nodes.each{ |n|
        if (node != "*") then
          hosts.push("node=\"#{n}\"")
        end
      }
    }
    if not hosts.empty? then
      query = "SELECT DISTINCT node FROM rights WHERE part<>\"*\" AND (#{hosts.join(" OR ")})"
      res = db.run_query(query)
      res.each_hash { |row|
        nodes_to_remove.push(row["node"])
      }
    end
    if (not nodes_to_remove.empty?) then
      if exec_specific.overwrite_existing_rights then
        hosts = Array.new
        nodes_to_remove.each { |node|
          hosts.push("node=\"#{node}\"")
        }
        query = "DELETE FROM rights WHERE part<>\"*\" AND (#{hosts.join(" OR ")})"
        db.run_query(query)
        Debug::distant_client_print("Some rights have been removed on the nodes #{nodes_to_remove.join(", ")}", client)
      else
        exec_specific.node_list.delete_if { |node|
          nodes_to_remove.include?(node)
        }
        Debug::distant_client_print("The nodes #{nodes_to_remove.join(", ")} have been removed from the rights assignation since another user has some rights on them", client)
      end
    end
    values_to_insert = Array.new
    exec_specific.node_list.each { |node|
      exec_specific.part_list.each { |part|
        if /\A[A-Za-z\.\-]+[0-9]*\[[\d{1,3}\-,\d{1,3}]+\][A-Za-z0-9\.\-]*\Z/ =~ node
          nodes = Nodes::NodeSet::nodes_list_expand("#{node}")
        else
          nodes = [node]
        end
        nodes.each{ |n|
          if ((node == "*") || (part == "*")) then
            #check if the rights are already inserted
            query = "SELECT * FROM rights WHERE user=\"#{exec_specific.user}\" AND node=\"#{n}\" AND part=\"#{part}\""
            res = db.run_query(query)
            values_to_insert.push("(\"#{exec_specific.user}\", \"#{n}\", \"#{part}\")") if (res.num_rows == 0)
          else
            values_to_insert.push("(\"#{exec_specific.user}\", \"#{n}\", \"#{part}\")")
          end
        }
      }
    }
    #add the rights
    if (not values_to_insert.empty?) then
      query = "INSERT INTO rights (user, node, part) VALUES #{values_to_insert.join(",")}"
      db.run_query(query)
    else
      Debug::distant_client_print("No rights added", client)
    end
  end

  # Remove some rights on the nodes defined in exec_specific.node_list
  # and on the parts defined in exec_specific.part_list to a specific
  # user defined in exec_specific.user
  #
  # Arguments
  # * config: instance of Config
  # * db: database handler
  # Output
  # * nothing
  def karights_delete_rights(exec_specific, client, db)
    exec_specific.node_list.each { |node|
      exec_specific.part_list.each { |part|
        if /\A[A-Za-z\.\-]+[0-9]*\[[\d{1,3}\-,\d{1,3}]+\][A-Za-z0-9\.\-]*\Z/ =~ node then
          nodes = Nodes::NodeSet::nodes_list_expand("#{node}")
        else
          nodes = [node]
        end
        nodes.each{ |n|
          query = "DELETE FROM rights WHERE user=\"#{exec_specific.user}\" AND node=\"#{n}\" AND part=\"#{part}\""
          db.run_query(query)
          Debug::distant_client_print("No rights have been removed", client) if (db.dbh.affected_rows == 0)
        }
      }
    }
  end

  ##################################
  #       Private Kaconsole        #
  ##################################

  ##################################
  #       Private Kaenv            #
  ##################################

  # List the environments of a user defined in exec_specific.user
  #
  # Arguments
  # * config: instance of Config
  # * db: database handler
  # Output
  # * print the environments of a given user
  def kaenv_list_environments(exec_specific, client, db)
    env = EnvironmentManagement::Environment.new
    if (exec_specific.user == "*") then #we show the environments of all the users
      if (exec_specific.show_all_version == false) then
        if (exec_specific.version != "") then
          query = "SELECT * FROM environments WHERE version=\"#{exec_specific.version}\" \
                                              AND visibility<>\"private\" \
                                              GROUP BY name \
                                              ORDER BY user,name"
        else
          query = "SELECT * FROM environments e1 \
                            WHERE e1.visibility<>\"private\" \
                            AND e1.version=(SELECT MAX(e2.version) FROM environments e2 \
                                                                   WHERE e2.name=e1.name \
                                                                   AND e2.user=e1.user \
                                                                   AND e2.visibility<>\"private\" \
                                                                   GROUP BY e2.user,e2.name) \
                            ORDER BY user,name"
        end
      else
        query = "SELECT * FROM environments WHERE visibility<>\"private\" ORDER BY user,name,version"
      end
    else
      #If the user wants to print the environments of another user, private environments are not shown
      if (exec_specific.user != exec_specific.true_user) then
        mask_private_env = true
      end
      if (exec_specific.show_all_version == false) then
        if (exec_specific.version != "") then
          if mask_private_env then
            query = "SELECT * FROM environments \
                              WHERE user=\"#{exec_specific.user}\" \
                              AND version=\"#{exec_specific.version}\" \
                              AND visibility<>\"private\" \
                              ORDER BY user,name"
          else
            query = "SELECT * FROM environments \
                              WHERE (user=\"#{exec_specific.user}\" AND version=\"#{exec_specific.version}\") \
                              OR (user<>\"#{exec_specific.user}\" AND version=\"#{exec_specific.version}\" AND visibility=\"public\") \
                              ORDER BY user,name"
          end
        else
          if mask_private_env then
            query = "SELECT * FROM environments e1\
                              WHERE e1.user=\"#{exec_specific.user}\" \
                              AND e1.visibility<>\"private\" \
                              AND e1.version=(SELECT MAX(e2.version) FROM environments e2 \
                                                                     WHERE e2.name=e1.name \
                                                                     AND e2.user=e1.user \
                                                                     AND e2.visibility<>\"private\" \
                                                                     GROUP BY e2.user,e2.name) \
                              ORDER BY e1.user,e1.name"
          else
            query = "SELECT * FROM environments e1\
                              WHERE (e1.user=\"#{exec_specific.user}\" \
                              OR (e1.user<>\"#{exec_specific.user}\" AND e1.visibility=\"public\")) \
                              AND e1.version=(SELECT MAX(e2.version) FROM environments e2 \
                                                                     WHERE e2.name=e1.name \
                                                                     AND e2.user=e1.user \
                                                                     AND (e2.user=\"#{exec_specific.user}\" \
                                                                     OR (e2.user<>\"#{exec_specific.user}\" AND e2.visibility=\"public\")) \
                                                                     GROUP BY e2.user,e2.name) \
                              ORDER BY e1.user,e1.name"
          end
        end
      else
        if mask_private_env then
          query = "SELECT * FROM environments WHERE user=\"#{exec_specific.user}\" \
                                              AND visibility<>\"private\" \
                                              ORDER BY name,version"
        else
          query = "SELECT * FROM environments WHERE user=\"#{exec_specific.user}\" \
                                              OR (user<>\"#{exec_specific.user}\" AND visibility=\"public\") \  
                                              ORDER BY user,name,version"

        end
      end
    end
    res = db.run_query(query)
    if (res.num_rows > 0) then
      env.short_view_header(client)
      res.each_hash { |row|
        env.load_from_hash(row)
        env.short_view(client)
      }
    else
      Debug::distant_client_print("No environment has been found", client)
    end
  end

  # Add an environment described in the file exec_specific.file
  #
  # Arguments
  # * config: instance of Config
  # * db: database handler
  # Output
  # * nothing
  def kaenv_add_environment(exec_specific, client, db)
    env = EnvironmentManagement::Environment.new
                         
    if env.load_from_file(exec_specific.file, exec_specific.file_content, @config.common.almighty_env_users, exec_specific.true_user, client) then
      query = "SELECT * FROM environments WHERE name=\"#{env.name}\" AND version=\"#{env.version}\" AND user=\"#{env.user}\""
      res = db.run_query(query)
      if (res.num_rows != 0) then
        Debug::distant_client_print("An environment with the name #{env.name} and the version #{env.version} has already been recorded for the user #{env.user}", client)
        return(1)
      end
      if (env.visibility == "public") then
        query = "SELECT * FROM environments WHERE name=\"#{env.name}\" AND version=\"#{env.version}\" AND visibility=\"public\""
        res = db.run_query(query)
        if (res.num_rows != 0) then
          Debug::distant_client_print("A public environment with the name #{env.name} and the version #{env.version} has already been recorded", client)
          return(1)
        end
      end
      query = "INSERT INTO environments (name, \
                                         version, \
                                         description, \
                                         author, \
                                         tarball, \
                                         preinstall, \
                                         postinstall, \
                                         kernel, \
                                         kernel_params, \
                                         initrd, \
                                         hypervisor, \
                                         hypervisor_params, \
                                         fdisk_type, \
                                         filesystem, \
                                         user, \
                                         environment_kind, \
                                         visibility, \
                                         demolishing_env) \
                               VALUES (\"#{env.name}\", \
                                       \"#{env.version}\", \
                                       \"#{env.description}\", \
                                       \"#{env.author}\", \
                                       \"#{env.flatten_tarball_with_md5()}\", \
                                       \"#{env.flatten_pre_install_with_md5()}\", \
                                       \"#{env.flatten_post_install_with_md5()}\", \
                                       \"#{env.kernel}\", \
                                       \"#{env.kernel_params}\", \
                                       \"#{env.initrd}\", \
                                       \"#{env.hypervisor}\", \
                                       \"#{env.hypervisor_params}\", \
                                       \"#{env.fdisk_type}\", \
                                       \"#{env.filesystem}\", \
                                       \"#{env.user}\", \
                                       \"#{env.environment_kind}\", \
                                       \"#{env.visibility}\", \
                                       \"#{env.demolishing_env}\")"
      db.run_query(query)
      return(0)
    end
  end

  # Delete the environment specified in exec_specific.env_name
  #
  # Arguments
  # * config: instance of Config
  # * db: database handler
  # Output
  # * nothing
  def kaenv_delete_environment(exec_specific, client, db)
    if (exec_specific.version != "") then
      version = exec_specific.version
    else
      version = _get_max_version(db, exec_specific.env_name, exec_specific.user, exec_specific.true_user)
    end
    query = "DELETE FROM environments WHERE name=\"#{exec_specific.env_name}\" \
                                      AND version=\"#{version}\" \
                                      AND user=\"#{exec_specific.true_user}\""
    db.run_query(query)
    if (db.get_nb_affected_rows == 0) then
      Debug::distant_client_print("No environment has been deleted", client)
      return(1)
    end
    return(0)
  end

  # Print the environment designed by exec_specific.env_name and that belongs to the user specified in exec_specific.user
  #
  # Arguments
  # * config: instance of Config
  # * db: database handler
  # Output
  # * print the specified environment that belongs to the specified user
  def kaenv_print_environment(exec_specific, client, db)
    env = EnvironmentManagement::Environment.new
    mask_private_env = false
    #If the user wants to print the environments of another user, private environments are not shown
    if (exec_specific.user != exec_specific.true_user) then
      mask_private_env = true
    end

    if (exec_specific.show_all_version == false) then
      if (exec_specific.version != "") then
        version = exec_specific.version
      else
        version = _get_max_version(db, exec_specific.env_name, exec_specific.user, exec_specific.true_user)
      end
      if mask_private_env then
        query = "SELECT * FROM environments WHERE name=\"#{exec_specific.env_name}\" \
                                            AND user=\"#{exec_specific.user}\" \
                                            AND version=\"#{version}\" \
                                            AND visibility<>\"private\""
      else
        query = "SELECT * FROM environments WHERE name=\"#{exec_specific.env_name}\" \
                                            AND user=\"#{exec_specific.user}\" \
                                            AND version=\"#{version}\""
      end
    else
      if mask_private_env then
        query = "SELECT * FROM environments WHERE name=\"#{exec_specific.env_name}\" \
                                            AND user=\"#{exec_specific.user}\" \
                                            AND visibility<>\"private\" \
                                            ORDER BY version"
      else
        query = "SELECT * FROM environments WHERE name=\"#{exec_specific.env_name}\" \
                                            AND user=\"#{exec_specific.user}\" \
                                            ORDER BY version"
      end
    end
    res = db.run_query(query)
    if (res.num_rows > 0) then
      res.each_hash { |row|
        Debug::distant_client_print("###", client)
        env.load_from_hash(row)
        env.full_view(client)
      }
    else
      Debug::distant_client_print("The environment does not exist", client)
    end
  end

  # Get the highest version of an environment
  #
  # Arguments
  # * db: database handler
  # * env_name: environment name
  # * user: owner of the environment
  # Output
  # * return the highest version number or -1 if no environment is found
  def _get_max_version(db, env_name, user, true_user)
    #If the user wants to print the environments of another user, private environments are not shown
    if (user != true_user) then
      mask_private_env = true
    end

    if mask_private_env then
      query = "SELECT MAX(version) FROM environments WHERE user=\"#{user}\" \
                                                     AND name=\"#{env_name}\" \
                                                     AND visibility<>\"private\""
    else
      query = "SELECT MAX(version) FROM environments WHERE user=\"#{user}\" \
                                                     AND name=\"#{env_name}\""
    end
    res = db.run_query(query)
    if (res.num_rows > 0) then
      row = res.fetch_row
      return row[0]
    else
      return -1
    end
  end


  # Update the md5sum of the tarball
  # Sub function of update_preinstall_md5
  #
  # * db: database handler
  # * env_name: environment name
  # * env_version: environment version
  # * env_user: environment user
  # Output
  # * nothing
  def _update_tarball_md5(db, env_name, env_version, env_user, true_user, client)
    if (env_version != "") then
      version = env_version
    else
      version = _get_max_version(db, env_name, env_user, true_user)
    end
    query = "SELECT * FROM environments WHERE name=\"#{env_name}\" \
                                        AND user=\"#{env_user}\" \
                                        AND version=\"#{version}\""
    res = db.run_query(query)
    res.each_hash  { |row|
      env = EnvironmentManagement::Environment.new
      env.load_from_hash(row)
      tarball = "#{env.tarball["file"]}|#{env.tarball["kind"]}|#{MD5::get_md5_sum(env.tarball["file"])}"
      
      query2 = "UPDATE environments SET tarball=\"#{tarball}\" WHERE name=\"#{env_name}\" \
                                                               AND user=\"#{env_user}\" \
                                                               AND version=\"#{version}\""
      db.run_query(query2)
      if (db.get_nb_affected_rows == 0) then
        Debug::distant_client_print("No update has been performed", client)
      end
    }
  end

  # Update the md5sum of the tarball
  #
  # * config: instance of Config
  # * db: database handler
  # Output
  # * nothing
  def kaenv_update_tarball_md5(exec_specific, client, db)
    _update_tarball_md5(db, exec_specific.env_name, exec_specific.version, exec_specific.user, exec_specific.true_user, client)
  end

  # Update the md5sum of the preinstall
  # Sub function of update_preinstall_md5
  #
  # * db: database handler
  # * env_name: environment name
  # * env_version: environment version
  # * env_user: environment user
  # Output
  # * nothing
  def _update_preinstall_md5(db, env_name, env_version, env_user, true_user, client)
    if (env_version != "") then
      version = env_version
    else
      version = _get_max_version(db, env_name, env_user, true_user)
    end
    query = "SELECT * FROM environments WHERE name=\"#{env_name}\" \
                                        AND user=\"#{env_user}\" \
                                        AND version=\"#{version}\""
    res = db.run_query(query)
    res.each_hash  { |row|
      env = EnvironmentManagement::Environment.new
      env.load_from_hash(row)
      if (env.preinstall != nil) then
        tarball = "#{env.preinstall["file"]}|#{env.preinstall["kind"]}|#{MD5::get_md5_sum(env.preinstall["file"])}|#{env.preinstall["script"]}"
        
        query2 = "UPDATE environments SET preinstall=\"#{tarball}\" WHERE name=\"#{env_name}\" \
                                                                    AND user=\"#{env_user}\" \
                                                                    AND version=\"#{version}\""
        db.run_query(query2)
        if (db.get_nb_affected_rows == 0) then
          Debug::distant_client_print("No update has been performed", client)
        end
      else
        Debug::distant_client_print("No preinstall to update", client)
      end
    }
  end

  # Update the md5sum of the preinstall
  #
  # * db: database handler
  # * config: instance of Config
  # Output
  # * nothing
  def kaenv_update_preinstall_md5(exec_specific, client, db)
    _update_preinstall_md5(db, exec_specific.env_name, exec_specific.version, exec_specific.user, exec_specific.true_user, client)
  end

  # Update the md5sum of the postinstall files
  # Sub function of update_postinstalls_md5
  #
  # * db: database handler
  # * env_name: environment name
  # * env_version: environment version
  # * env_user: environment user
  # Output
  # * nothing
  def _update_postinstall_md5(db, env_name, env_version, env_user, true_user, client)
    if (env_version != "") then
      version = env_version
    else
      version = _get_max_version(db, env_name, env_user, true_user)
    end
    query = "SELECT * FROM environments WHERE name=\"#{env_name}\" \
                                        AND user=\"#{env_user}\" \
                                        AND version=\"#{version}\""
    res = db.run_query(query)
    res.each_hash  { |row|
      env = EnvironmentManagement::Environment.new
      env.load_from_hash(row)
      if (env.postinstall != nil) then
        postinstall_array = Array.new
        env.postinstall.each { |p|
          postinstall_array.push("#{p["file"]}|#{p["kind"]}|#{MD5::get_md5_sum(p["file"])}|#{p["script"]}")
        }
        query2 = "UPDATE environments SET postinstall=\"#{postinstall_array.join(",")}\" \
                                      WHERE name=\"#{env_name}\" \
                                      AND user=\"#{env_user}\" \
                                      AND version=\"#{version}\""
        db.run_query(quer y2)
        if (db.get_nb_affected_rows == 0) then
          Debug::distant_client_print("No update has been performed", client)
        end
      else
        Debug::distant_client_print("No postinstall to update", client)
      end
    }
  end

  # Update the md5sum of the postinstall files
  #
  # * config: instance of Config
  # * db: database handler
  # Output
  # * nothing
  def kaenv_update_postinstall_md5(exec_specific, client, db)
    _update_postinstall_md5(db, exec_specific.env_name, exec_specific.version, exec_specific.user, exec_specific.true_user, client)
  end

  # Remove the demolishing tag on an environment
  #
  # Arguments
  # * config: instance of Config
  # * db: database handler
  # Output
  # * nothing
  def kaenv_remove_demolishing_tag(exec_specific, client, db)
    #if no version number is given, we only remove the demolishing tag on the last version
    if (exec_specific.version != "") then
      version = exec_specific.version
    else
      version = _get_max_version(db, exec_specific.env_name, exec_specific.user, exec_specific.true_user)
    end
    query = "UPDATE environments SET demolishing_env=0 WHERE name=\"#{exec_specific.env_name}\" \
                                                       AND user=\"#{exec_specific.true_user}\" \
                                                       AND version=\"#{version}\""
    db.run_query(query)
    if (db.get_nb_affected_rows == 0) then
      Debug::distant_client_print("No update has been performed", client)
    end
  end

  # Modify the visibility tag of an environment
  #
  # Arguments
  # * config: instance of Config
  # * db: database handler
  # Output
  # * nothing
  def kaenv_set_visibility_tag(exec_specific, client, db)
    if (exec_specific.visibility_tag == "public") && (not config.common.almighty_env_users.include?(exec_specific.true_user)) then
      Debug::distant_client_print("Only the environment administrators can set the \"public\" tag", client)
    else
      query = "UPDATE environments SET visibility=\"#{exec_specific.visibility_tag}\" \
                                   WHERE name=\"#{exec_specific.env_name}\" \
                                   AND user=\"#{exec_specific.user}\" \
                                   AND version=\"#{exec_specific.version}\""
      db.run_query(query)
      if (db.get_nb_affected_rows == 0) then
        Debug::distant_client_print("No update has been performed", client)
      end
    end
  end

  # Move some file locations in the environment table
  #
  # Arguments
  # * config: instance of Config
  # * db: database handler
  # Output
  # * nothing
  def kaenv_move_files(exec_specific, client, db)
    if (not @config.common.almighty_env_users.include?(exec_specific.true_user)) then
      Debug::distant_client_print("Only the environment administrators can move the files in the environments", client)
    else
      query = "SELECT * FROM environments"
      res = db.run_query(query)
      if (res.num_rows > 0) then
        #Let's check each environment
        res.each_hash { |row|
          exec_specific.files_to_move.each { |file|
            ["tarball", "preinstall", "postinstall"].each { |kind_of_file|
              if row[kind_of_file].include?(file["src"]) then
                modified_file = row[kind_of_file].gsub(file["src"], file["dest"])
                query2 = "UPDATE environments SET #{kind_of_file}=\"#{modified_file}\" \
                                            WHERE id=#{row["id"]}"
                db.run_query(query2)
                if (db.get_nb_affected_rows > 0) then
                  Debug::distant_client_print("The #{kind_of_file} of {#{row["name"]},#{row["version"]},#{row["user"]}} has been updated", client)
                  Debug::distant_client_print("Let's now update the md5 for this file", client)
                  send("_update_#{kind_of_file}_md5".to_sym, db, row["name"], row["version"], row["user"])
                end
              end
            }
          }
        }
      else
        Debug::distant_client_print("There is no recorded environment", client)
      end
    end
  end
end


begin
  config = ConfigInformation::Config.new(false)
rescue
  puts "Bad configuration: #{$!}"
  exit(1)
end
db = Database::DbFactory.create(config.common.db_kind)
Signal.trap("TERM") do
  puts "TERM trapped, let's clean everything ..."
  exit(1)
end
Signal.trap("INT") do
  puts "SIGINT trapped, let's clean everything ..."
  exit(1)
end
if not db.connect(config.common.deploy_db_host,
                  config.common.deploy_db_login,
                  config.common.deploy_db_passwd,
                  config.common.deploy_db_name)
  puts "Cannot connect to the database"
  exit(1)
else
  db.disconnect
  kadeployServer = KadeployServer.new(config, 
                                      Managers::WindowManager.new(config.common.reboot_window, config.common.reboot_window_sleep_time),
                                      Managers::WindowManager.new(config.common.nodes_check_window, 1))
  puts "Launching the Kadeploy RPC server"
  uri = "druby://#{config.common.kadeploy_server}:#{config.common.kadeploy_server_port}"
  DRb.start_service(uri, kadeployServer)
  DRb.thread.join
end
