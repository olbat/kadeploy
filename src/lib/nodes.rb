# Kadeploy 3.0
# Copyright (c) by INRIA, Emmanuel Jeanvoine - 2008, 2009
# CECILL License V2 - http://www.cecill.info
# For details on use and redistribution please refer to License.txt


module Nodes
  class NodeCmd
    attr_accessor :reboot_soft_rsh
    attr_accessor :reboot_soft_ssh
    attr_accessor :reboot_hard
    attr_accessor :reboot_very_hard
    attr_accessor :console
  end

  class Node
    attr_accessor :hostname   #fqdn
    attr_accessor :ip         #aaa.bbb.ccc.ddd
    attr_accessor :cluster
    attr_accessor :state      #OK,KO
    attr_accessor :current_step
    attr_accessor :last_cmd_exit_status
    attr_accessor :last_cmd_stdout
    attr_accessor :last_cmd_stderr
    attr_accessor :cmd

    # Constructor of Node
    #
    # Arguments
    # * hostname: name of the host
    # * ip: ip of the host
    # * cluster: name of the cluster
    # * cmd: instance of NodeCmd
    # Output
    # * nothing
    def initialize(hostname, ip, cluster, cmd)
      @hostname=hostname
      @ip=ip
      @cluster = cluster
      @state="OK"
      @cmd = cmd
    end
    
    # Make a string with the characteristics of a node
    #
    # Arguments
    # * dbg(opt): boolean that specifies if the output contains stderr
    # Output
    # * return a string that contains the information
    def to_s(dbg = false)
      if (dbg) && (last_cmd_stderr != nil) then
        return "#{@hostname} (#{@last_cmd_stderr})"
      else
        return "#{@hostname}"
      end
    end
  end

  class NodeSet
    attr_accessor :set
    
    # Constructor of NodeSet
    #
    # Arguments
    # * nothing
    # Output
    # * nothing
    def initialize
      @set = Array.new
    end

    private

    # Sort hostname
    # 
    # Arguments
    # * hosts: array of hostname
    # Output
    # * Sorted hostname 
    def sort_host(hosts)
      hosts1 = []
      hosts2 = []
      hosts3 = []
      hosts4 = []
      hosts.each{|host|
        case host 
        when /\A[A-Za-z\.\-]+\Z/
          hosts1 += [host]
        when /\A[A-Za-z\.\-]+[0-9]+\Z/
          hosts2 += [host]
        when /\A([A-Za-z\.\-]+)[0-9]+([\-\.][A-Za-z\.\-0-9]+)\Z/
          hosts3 += [host]
        else
          hosts4 += [host]
        end
      }
      return hosts1.sort + hosts2.sort + hosts3 + hosts4.sort
    end


    # Develop list of numbers into array of numbers
    # eg: 5-9 => [5 6 7 8 9]
    #
    # Arguments
    # * interval: list of numbers(eg: "5-16") of hostnames
    #
    # Output
    # * returns array of numbers 
    def NodeSet::develop_interval(interval)
      numbers_array =[]
      if /(\d{1,3})-(\d{1,3})/ =~ interval
        content = Regexp.last_match
        if content[1].length == content[2].length
          numbers_array += (content[1] .. content[2]).to_a
        else
          numbers_array += (content[1].to_i .. content[2].to_i).to_a
        end
      else
        numbers_array += [interval]
      end
      return numbers_array
    end
    
    # Make an array of figures 
    # eg: 1,3,5-9 => [1 3 5 6 7 8 9]
    #
    # Arguments
    # * numbers_list: list of numbers(eg: "1,3,5-16") of hostnames
    #
    # Output
    # * returns array of numbers 
    def NodeSet::make_array_of_figures(numbers_list)
      numbers_array = []
      if numbers_list.include? ?, 
        patterns=numbers_list.split(",")
        patterns.each{|pattern|
          numbers_array += NodeSet::develop_interval(pattern) 
        }
      else
        numbers_array = NodeSet::develop_interval(numbers_list) 
      end
      return numbers_array
    end

    # Make an array of hostnames 
    #
    # Arguments
    # * numbers_array: array of numbers 
    # * head_host: the common beginning of hostnames
    # * tail_host: the common end of hostnames
    #
    # Output
    # * returns array of hostname 
    def NodeSet::make_array_of_hostnames(numbers_array,head_host,tail_host)
      hosts_array = []
      numbers_array.each{|n|
        hosts_array += [head_host + n.to_s + tail_host]
      }
      return hosts_array
    end

    # Make an array which separates numbers and the letter
    # eg: cors115-ib8002 => [ cors , 115 , -ib , 8002 ]
    #
    # Arguments
    # * hostname : string
    #
    # Output
    # * returns array with separation
    def NodeSet::separate_number_letter(hostname)
      letter = hostname.split(/[0-9]+/)
      number = hostname.split(/[A-Za-z\-.]+/)
      res = []
      for i in (0 ... letter.length)
        res += [letter[i]]
        res += [number[i+1]]
      end
      res.delete(nil)
      return res
    end

    # Create array of head hostname, tail hostname and the distinct 
    #
    # Arguments
    # * hostname1 : string
    # * hostname2 : string
    #
    # Output
    # * return array : 
    # * [ the beginning of the hostname , the end of the hostname, [number1] , [number2] ]
    def NodeSet::diff_hosts(hostname1,hostname2)
      similar_array = []
      diff_array = []
      head = ""
      tail = []
      array_host1 = separate_number_letter(hostname1)
      array_host2 = separate_number_letter(hostname2)
      if array_host1.length == array_host2.length
        for i in (0 ... array_host1.length)
          if array_host1[i] == array_host2[i]
            similar_array += [ array_host1[i] ]
          else
            if array_host1[i] =~ /[0-9]+/ && array_host2[i] =~ /[0-9]+/
              diff_array += [[array_host1[i]] + [array_host2[i]]]
              head = similar_array.to_s
              similar_array = []
            end
          end
        end
      end
      tail = similar_array.to_s
      return [[head] + [tail] + diff_array]
    end

    # Check two hostnames are close (the difference is only one number) 
    #
    # Arguments
    # * hostname1 : string
    # * hostname2 : string
    #
    # Output
    # * return false if it is too remote 
    def NodeSet::cmp_hosts(hostname1,hostname2)
      close = true
      i = 0
      j = 0
      array_host1 = separate_number_letter(hostname1)
      array_host2 = separate_number_letter(hostname2)
      if array_host1.length == array_host2.length
        while close == true && i < array_host1.length
          if array_host1[i] != array_host2[i] 
            j += 1
            close = false if (array_host1[i] =~ /[a-zA-Z\-\.]+/ || array_host2[i] =~ /[a-zA-Z\-\.]+/ || j>1) 
          end
          i+=1
        end
      else
        close = false
      end
      return close
    end

    # find one remote host
    #
    # Arguments
    # * array of hostname 
    # * index of host 
    #
    # Output
    # * returns array of folded hostnames 
    def NodeSet::remote_host_find(name_array,i)
      case i 
      when 1
        array = name_array[i-1]
      when name_array.length-1
        array = name_array[i]
      else
        if cmp_hosts(name_array[i-2],name_array[i-1]) == false
          array = name_array[i-1]
        end
      end
      return [array]
    end

    # Convert a numbers array into numbers list 
    # [ 001 , 002 , 003 , 005 , 007 , 008 ] => "001-003,005,007-008"
    #
    # Arguments
    # * numbers_array : array of numbers
    #
    # Output
    # * return list of numbers 
    def NodeSet::numbers_fold(numbers_array)
      fold=""
      i=1
      numbers_array=numbers_array.sort { |a,b|
        a.to_i <=> b.to_i
      }
      while i < numbers_array.length
        fold += numbers_array[i-1]
        if (numbers_array[i].to_i - numbers_array[i-1].to_i != 1)
          fold += "," 
          fold +=numbers_array[i] if i == numbers_array.length-1
          i+=1
        else
          while (numbers_array[i].to_i - numbers_array[i-1].to_i == 1)
            if (fold[fold.length-1,1] != '-')
              fold += "-"
            end
            i+=1
            if (numbers_array[i].to_i - numbers_array[i-1].to_i != 1 && i  == numbers_array.length)
              fold += numbers_array[i-1]
            end
          end
        end
      end
      return fold
    end

    # make one list folds
    #
    # Arguments
    # * numbers_array : array of numbers
    # * head : the beginning of hostname
    # * tail : the end of hostname 
    #
    # Output
    # * return list of group nodes
    # * eg: cors[001-128].ocre.cea.fr 
    def NodeSet::nodes_group_list_fold(numbers_array,head,tail)
      list_number = numbers_fold(numbers_array)
      return head + "[" + list_number + "]" + tail
    end

    public
    # Convert a string of hostnames' factorization into an array of hosts 
    #
    # Argument
    # * list_factor_hosts: string of host's factorization
    #
    # Output
    # * returns array of hosts
    def NodeSet::nodes_list_expand(list_factor_hosts)
      if /\A([A-Za-z\.\-]+[0-9]*[\.\-]*)\[([\d{1,3}\-,\d{1,3}]+)\]([A-Za-z0-9\.\-]*)\Z/ =~ list_factor_hosts
        content = Regexp.last_match
        head = content[1]
        numbers_list = content[2]
        tail = content[3]
      else 
        if /\A(\d{1,3}\.\d{1,3}\.\d{1,3}\.)\[([\d{1,3}\-,\d{1,3}]+)\]\Z/ =~ list_factor_hosts
          content = Regexp.last_match
          head = content[1]
          numbers_list = content[2]
          tail = ""
        else
          puts "ips or hostnames not correct"
        end
      end  
      array_figures = make_array_of_figures(numbers_list)
      return make_array_of_hostnames(array_figures,head,tail)
    end  

    def method_missing(method_sym, *args)
      raise "Wrong method: #{method_sym} !!!"
    end

    # make an array of list folds
    # eg: [cors[001-010],cors[001-152]-ilo]
    #
    # Arguments
    # * nothing
    # Output
    # * returns array of folded hostnames 
    def to_s_fold()
      name_array = make_array_of_hostname()
      array = []
      i=1
      j=0
      if name_array.length != 1
        name_array = sort_host(name_array)
        while i < name_array.length
          temp = []
          # creation of list folds
          while (i < name_array.length && NodeSet::cmp_hosts(name_array[i-1],name_array[i]) != false)
            u = NodeSet::diff_hosts(name_array[i-1],name_array[i])
            # addition of head and tail hostname:
            if (temp[j] != u[0][0] || temp[j+1] != u[0][1])
              temp += [u[0][0]]
              temp += [u[0][1]]
              j = temp.length-2
            end
            # addition of the list of numbers: 
            temp += [u[0][2][0]] if temp[temp.length-1]!= u[0][2][0]
            temp += [u[0][2][1]] 
            i += 1
          end
          array += [NodeSet::nodes_group_list_fold(temp[2,temp.length-2],temp[0],temp[1])] if temp != []
          # addition of remote hosts (depend on the position in the array)
          array += NodeSet::remote_host_find(name_array,i) 
          i+=1
        end
      else
        array += [name_array]
      end
      return array.compact
    end

    # Add a node to the set
    #
    # Arguments
    # * node: instance of Node
    # Output
    # * nothing
    def push(node)
      @set.push(node)
    end

    # Test if the node set is empty
    #
    # Arguments
    # * nothing
    # Output
    # * return true if the set is empty, false otherwise
    def empty?
      return @set.empty?
    end

    # Duplicate a NodeSet
    #
    # Arguments
    # * dest: destination NodeSet
    # Output
    # * nothing
    def duplicate(dest)
      @set.each { |node|
        dest.push(node.clone)
      }
    end

    # Duplicate a NodeSet and free it
    #
    # Arguments
    # * dest: destination NodeSet
    # Output
    # * nothing
    def duplicate_and_free(dest)
      @set.each { |node|
        dest.push(node.clone)
      }
      free
    end

    # Add a NodeSet to an existing one
    #
    # Arguments
    # * node_set: NodeSet to add to the current one
    # Output
    # * nothing
    def add(node_set)
      if not node_set.empty?
        node_set.set.each { |node|
          @set.push(node)
        }
      end
    end

    # Extract a given number of elements from a NodeSet
    #
    # Arguments
    # * n: number of element to extract
    # Output
    #  * return a new NodeSet if there are enough elements in the source NodeSet, nil otherwise
    def extract(n)
      if (n <= @set.length) then
        new_set = NodeSet.new
        n.times {
          new_set.push(@set.shift)
        }
        return new_set
      else
        return nil
      end
    end

    # Test if the state of all the nodes in the set is OK
    #
    # Arguments
    # * nothing
    # Output
    # * return true if the state of all the nodes is OK     
    def all_ok?
      @set.each { |node|
        if node.state == "KO"
          return false
        end
      }
      return true
    end

    # Free a NodeSet
    #
    # Arguments
    # * nothing
    # Output
    # * nothing
    def free
      @set.delete_if { |node| true }
    end

    # Create an array from the IP of the nodes in a NodeSet
    #
    # Arguments
    # * nothing
    # Output
    # * return an array of IP
    def make_array_of_ip
      res = Array.new
      @set.each { |n|
        res.push(n.ip)
      }
      return res
    end

    # Create an array from the hostname of the nodes in a NodeSet
    #
    # Arguments
    # * nothing
    # Output
    # * return an array of hostname
    def make_array_of_hostname
      res = Array.new
      @set.each { |n|
        res.push(n.hostname)
      }
      return res
    end

    # Create a sorted array (from the hostname point of view) of the nodes in a NodeSet
    #
    # Arguments
    # * nothing
    # Output
    # * return a sorted array of nodes
    def make_sorted_array_of_nodes
      return @set.sort { |str_x,str_y|
        x = str_x.hostname.gsub(/[a-zA-Z\-\.]/,"").to_i
        y = str_y.hostname.gsub(/[a-zA-Z\-\.]/,"").to_i
        x <=> y
      }
    end

    # Make a string with the characteristics of the nodes of a NodeSet
    #
    # Arguments
    # * dbg (opt): specify if the debug mode must be used
    # * delimiter (opt): specify a delimiter
    # Output
    # * return a string that contains the information
    def to_s(dbg = false, delimiter = ", ")
      out = Array.new
      @set.each { |node|
        out.push(node.to_s(dbg))
      }
      return out.join(delimiter)
    end

    def to_h(dbg = false)
      out = Hash.new
      @set.each { |node|
        out[node.hostname] = Hash["ip" => node.ip, "cluster" => node.cluster, "state" => node.state,
                                  "current_step" => node.current_step,
                                  "last_cmd_exit_status" => node.last_cmd_exit_status,
                                  "last_cmd_stdout" => node.last_cmd_stdout,
                                  "last_cmd_stderr" => node.last_cmd_stderr,
                                  "cmd" => node.cmd]
      }
      return out
    end

    # Get the number of elements
    #
    # Arguments
    # * nothing
    # Output
    # * return the number of elements
    def length
      return @set.length
    end

    # Make a hashtable that groups the nodes in a NodeSet by cluster
    #
    # Arguments
    # * nothing
    # Output
    # * return an Hash that groups the nodes by cluster (each entry is a NodeSet)
    def group_by_cluster
      ht = Hash.new
      @set.each { |node| 
        ht[node.cluster] = NodeSet.new if ht[node.cluster].nil?
        ht[node.cluster].push(node.clone)
      }
      return ht
    end

    # Get the number of clusters involved in the NodeSet
    #
    # Arguments
    # * nothing
    # Output
    # * return the number of clusters involved
    def get_nb_clusters
      return group_by_cluster.length
    end

    # Get a Node in a NodeSet by its hostname
    #
    # Arguments
    # * hostname: name of the node searched
    # Output
    # * return nil if the node can not be found
    def get_node_by_host(hostname)
      @set.each { |node|
        return node if (node.hostname == hostname)
      }
      return nil
    end

    # Set an error message to a NodeSet
    #
    # Arguments
    # * msg: error message
    # Output
    # * nothing
    def set_error_msg(msg)
      @set.each { |node|
        node.last_cmd_stderr = msg
      }
    end

    # Make the difference with another NodeSet
    #
    # Arguments
    # * sub: NodeSet that contains the nodes to remove
    # Output
    # * return the NodeSet that contains the diff
    def diff(sub)
      dest = NodeSet.new
      @set.each { |node|
        if (sub.get_node_by_host(node.hostname) == nil) then
          dest.push(node.clone)
        end
      }
      return dest
    end

    # Check if some nodes are currently in deployment
    #
    # Arguments
    # * db: database handler
    # * purge: period after what the data in the nodes table can be pruged (ie. there is no running deployment on the nodes)
    # Output
    # * return an array that contains two NodeSet ([0] is the good nodes set and [1] is the bad nodes set)
    def check_nodes_in_deployment(db, purge)
      bad_nodes = NodeSet.new
      hosts = Array.new
      @set.each { |node|
        hosts.push("hostname=\"#{node.hostname}\"")
      }
      query = "SELECT hostname FROM nodes WHERE state=\"deploying\" AND date > #{Time.now.to_i - purge} AND (#{hosts.join(" OR ")})"
      res = db.run_query(query)
      if (res != nil) then
        while (row = res.fetch_row) do
          bad_nodes.push(get_node_by_host(row[0]).clone)
        end
      end
      good_nodes = diff(bad_nodes)
      return [good_nodes, bad_nodes]
    end

    # Set the deployment state on a NodeSet
    #
    # Arguments
    # * state: state of the nodes (prod_env, recorded_env, deploying, deployed and aborted)
    # * env_id: id of the environment deployed on the nodes
    # * db: database handler
    # * user: user name
    # Output
    # * return true if the state has been correctly modified, false otherwise
    def set_deployment_state(state, env_id, db, user)
      hosts = Array.new
      @set.each { |node|
        hosts.push("hostname=\"#{node.hostname}\"")
      }
      date = Time.now.to_i
      case state
      when "deploying"
        query = "DELETE FROM nodes WHERE #{hosts.join(" OR ")}"
        db.run_query(query)
        @set.each { |node|
          query = "INSERT INTO nodes (hostname, state, env_id, date, user) \
                   VALUES (\"#{node.hostname}\",\"deploying\",\"#{env_id}\",\"#{date}\",\"#{user}\")"
          db.run_query(query)
        }
      when "deployed"
        @set.each { |node|
          query = "UPDATE nodes SET state=\"deployed\" WHERE hostname=\"#{node.hostname}\""
          db.run_query(query)
        }
      when "prod_env"
         @set.each { |node|
          query = "UPDATE nodes SET state=\"prod_env\" WHERE hostname=\"#{node.hostname}\""
          db.run_query(query)
        } 
      when "recorded_env"
         @set.each { |node|
          query = "UPDATE nodes SET state=\"recorded_env\" WHERE hostname=\"#{node.hostname}\""
          db.run_query(query)
        }
      when "deploy_env"
         @set.each { |node|
          query = "UPDATE nodes SET state=\"deploy_env\",user=\"#{user}\",env_id=\"-1\",date=\"#{date}\" WHERE hostname=\"#{node.hostname}\""
          db.run_query(query)
        } 
      when "aborted"
        @set.each { |node|
          query = "UPDATE nodes SET state=\"aborted\" WHERE hostname=\"#{node.hostname}\""
          db.run_query(query)
        }
      when "deploy_failed"
        @set.each { |node|
          query = "UPDATE nodes SET state=\"deploy_failed\" WHERE hostname=\"#{node.hostname}\""
          db.run_query(query)
        }          
      else
        return false
      end
      return true
    end

    # Check if one node in the set has been deployed with a demolishing environment
    #
    # Arguments
    # * db: database handler
    # * threshold: specify the minimum number of failures to consider a envrionement as demolishing
    # Output
    # * return true if at least one node has been deployed with a demolishing environment
    def check_demolishing_env(db, threshold)
      hosts = Array.new
      @set.each { |node|
        hosts.push("hostname=\"#{node.hostname}\"")
      }
      query = "SELECT hostname FROM nodes \
                               INNER JOIN environments ON nodes.env_id=environments.id \
                               WHERE demolishing_env>#{threshold} AND (#{hosts.join(" OR ")})"
      res = db.run_query(query)
      return (res.num_rows > 0)
    end

    # Tag some environments as demolishing
    #
    # Arguments
    # * db: database handler
    # Output
    # * return nothing
    def tag_demolishing_env(db)
      if not empty? then
        hosts = Array.new
        @set.each { |node|
          hosts.push("hostname=\"#{node.hostname}\"")
        }
        query = "SELECT DISTINCT(env_id) FROM nodes WHERE #{hosts.join(" OR ")}"
        res = db.run_query(query)
        while (row = res.fetch_row) do
          query2 = "UPDATE environments SET demolishing_env=demolishing_env+1 WHERE id=\"#{row[0]}\""
          db.run_query(query2)
        end
      end
    end
  end
end
