# Object used for simplified communication with a SGE batch server
#
# @api private
class OodCore::Job::Adapters::Sge::Batch
  using OodCore::Refinements::HashExtensions
  require "ood_core/job/adapters/sge/qstat_xml_f_r_listener"
  require "ood_core/job/adapters/sge/helper"
  require "ood_core/refinements/hash_extensions"
  require "tempfile"
  require 'time'

  class Error < StandardError; end

  # @param opts [#to_h] the options defining this adapter
  # @option opts [Batch] :batch The Sge batch object
  #
  # @api private
  # @see Factory.build_sge
  def initialize(config)
    @cluster = config.fetch(:cluster, nil)
    @conf    = Pathname.new(config.fetch(:conf, nil))
    @bin     = Pathname.new(config.fetch(:bin, nil))

    @helper = OodCore::Job::Adapters::Sge::Helper.new
  end

  # Get OodCore::Job::Info for every enqueued job, optionally filtering on owner
  # @param owner [#to_s] the owner or owner list
  # @return [Array<OodCore::Job::Info>]
  def get_all(owner: nil)
    listener = QstatXmlFrListener.new
    argv = ['qstat', '-r', '-xml']
    argv += ['-u', owner] unless owner.nil?
    parser = REXML::Parsers::StreamParser.new(call(*argv), listener)
    parser.parse

    listener.parsed_jobs.map{|job_hash| OodCore::Job::Info.new(**post_process_qstat_job_hash(job_hash))}
  end

  # Get OodCore::Job::Info for a job_id that may still be in the queue
  # It is not ideal to load everything just to get the output of a single job,
  # but SGE's qstat does not give a way to get the status of an enqueued job 
  # with qstat -j $jobid
  # 
  # @param job_id [#to_s]
  # @return [OodCore::Job::Info]
  def get_info_enqueued_job(job_id)
    job_info = get_all.find{|job_info| job_info.id == job_id.to_s}
    job_info = OodCore::Job::Info.new(id: job_id, status: :completed) if job_info.nil?
      
    job_info
  end

  # Get OodCore::Job::Info for a job that may be in the accounting file
  # @param job_id [#to_s]
  # @return [OodCore::Job::Info, nil]
  def get_info_historical_job(job_id)
    argv = ['qacct', '-j', job_id.to_s]
    
    begin
      result = call(*argv).strip
    rescue Error
      return nil
    end

    job_hash = @helper.parse_qacct_output(result)

    OodCore::Job::Info.new(**post_process_qacct_job_hash(job_hash))
  end

  # Call qhold
  # @param job_id [#to_s]
  # @return [void]
  def hold(job_id)
    call('qhold', job_id)
  end

  # Call qrls
  # @param job_id [#to_s]
  # @return [void]
  def release(job_id)
    call('qrls', job_id)
  end

  # Call qdel
  # @param job_id [#to_s]
  # @return [void]
  def delete(job_id)
    call('qdel', job_id)
  end

  # Call qsub with arguments and the scripts content
  # @param job_id [#to_s]
  # @return job_id [String]
  def submit(content, args)
      cmd = ['qsub'] + args
      @helper.parse_job_id_from_qsub(call(*cmd, :stdin => content))
  end

  # Call a forked SGE command for a given batch server
  def call(cmd, *args, env: {}, stdin: "", chdir: nil)
    cmd = cmd.to_s
    cmd = @bin.join(cmd).to_s if @bin
    args = args.map(&:to_s)
    env = env.to_h.each_with_object({}) { |(k, v), h| h[k.to_s] = v.to_s }
    chdir ||= "."
    o, e, s = Open3.capture3(env, cmd, *args, stdin_data: stdin.to_s, chdir: chdir.to_s)
    s.success? ? o : raise(Error, e)
  end

  # Adapted from http://www.softpanorama.org/HPC/Grid_engine/Queues/queue_states.shtml
  STATE_MAP = {
    'EhRqw'   => :undetermined, # all pending states with error
    'Ehqw'    => :undetermined, # all pending states with error
    'Eqw'     => :undetermined, # all pending states with error
    'RS'      => :suspended,    # all suspended with re-submit
    'RT'      => :suspended,    # all suspended with re-submit
    'Rr'      => :running,      # running, re-submit
    'Rs'      => :suspended,    # all suspended with re-submit
    'Rt'      => :running,      # transferring, re-submit
    'RtS'     => :suspended,    # all suspended with re-submit
    'RtT'     => :suspended,    # all suspended with re-submit
    'Rts'     => :suspended,    # all suspended with re-submit
    'S'       => :suspended,    # queue suspended
    'T'       => :suspended,    # queue suspended by alarm
    'dRS'     => :completed,    # all running and suspended states with deletion
    'dRT'     => :completed,    # all running and suspended states with deletion
    'dRr'     => :completed,    # all running and suspended states with deletion
    'dRs'     => :completed,    # all running and suspended states with deletion
    'dRt'     => :completed,    # all running and suspended states with deletion
    'dS'      => :completed,    # all running and suspended states with deletion
    'dT'      => :completed,    # all running and suspended states with deletion
    'dr'      => :completed,    # all running and suspended states with deletion
    'ds'      => :completed,    # all running and suspended states with deletion
    'dt'      => :completed,    # all running and suspended states with deletion
    'hRwq'    => :queued_held,  # pending, system hold, re-queue
    'hqw'     => :queued_held,  # pending, system hold
    'qw'      => :queued,       # pending
    'r'       => :running,      # running
    's'       => :suspended,    # suspended
    't'       => :running,      # transferring
    'tS'      => :suspended,    # queue suspended
    'tT'      => :suspended,    # queue suspended by alarm
    'ts'      => :suspended,    # obsuspended
  }

  def translate_state(sge_state_code)
    STATE_MAP.fetch(sge_state_code, :undetermined)
  end

  def post_process_qstat_job_hash(job_hash)
    # dispatch is not set if the job is not running
    if ! job_hash.key?(:wallclock_time)
      job_hash[:wallclock_time] = job_hash.key?(:dispatch_time) ? Time.now.to_i - job_hash[:dispatch_time] : 0  
    end
    
    job_hash[:status] = translate_state(job_hash[:status])

     job_hash
  end

  def post_process_qacct_job_hash(job_hash)
    job_hash[:procs] = job_hash[:slots].to_i
    job_hash[:id] = job_hash[:jobnumber]
    job_hash[:status] = :completed
    job_hash[:job_name] = job_hash[:jobname]
    job_hash[:accounting_id] = job_hash[:project] unless job_hash[:project] == 'NONE'
    job_hash[:queue_name] = job_hash[:qname]
    job_hash[:job_owner] = job_hash[:owner]
    job_hash[:wallclock_time] = job_hash[:ru_wallclock].to_i
    job_hash[:submission_time] = Time.parse(job_hash[:qsub_time])
    job_hash[:dispatch_time] = Time.parse(job_hash[:start_time])

    job_hash
  end
end