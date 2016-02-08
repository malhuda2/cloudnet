class DockerProvision
  include Sidekiq::Worker
  sidekiq_options unique: true
  sidekiq_options :retry => 5
  attr_reader :server_id, :role, :job_id
  
  FINAL_STATUS = %w(Failed Done Error Aborted)
  POLLING_TIME = 30.seconds
  
  class ProvisionerError < StandardError; end
    
  def perform(server_id, role)
    @server_id = server_id
    @role = role
    @job_id = nil
    
    resp = send_data_to_provisioner
    case resp.status
    when 200..209
      @job_id = resp.body
      status = wait_for_server_provisioned(job_id)
      finalize_build(status[:status])
    else 
      raise(ProvisionerError, resp.status)
    end
    
  rescue => e
    ErrorLogging.new.track_exception(e, extra: prov_error_params)
  end
  
  def send_data_to_provisioner
    provision_tasks.create(server_id, role)
  end
  
  def wait_for_server_provisioned(job_id)
    status = nil
    loop do
      status = job_status(job_id)
      break if status.nil? || status[:status].in?(FINAL_STATUS)
      sleep POLLING_TIME
    end
    status
  end
  
  def finalize_build(status)
    raise(ProvisionerError, status) unless status == "Done"
  rescue => e
    Rails.logger.warn "Provisioner of #{role} for server #{server_id} failed"
    ErrorLogging.new.track_exception(e, extra: prov_error_params)
  ensure
    server = Server.find(server_id)
    unset_server_from_provision(server)
    user_id = server.user.id
    ServerTasks.new.perform(:refresh_server, user_id, server_id)
  end
  
  def job_status(job_id)
    resp = provision_tasks.status(job_id)
    resp.status == 200 ? JSON.parse(resp.body).symbolize_keys : {status: "Error"}
  end
  
  def unset_server_from_provision(server)
    server.update_attribute(:in_provision, false)
  end
  
  def prov_error_params
    { source: 'DockerProvision', server_id: server_id,
      role: role, job_id: job_id,
      provisioner_addr: provision_tasks.prov_server
    }
  end
  
  def provision_tasks
    @provision_tasks ||= DockerProvisionerTasks.new
  end
end