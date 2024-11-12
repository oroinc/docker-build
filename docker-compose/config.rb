#!/usr/bin/ruby

require 'base64'
require 'erb'
require 'fileutils'
require 'json'
require 'openssl'
require 'resolv'
require 'securerandom'
require 'uri'
require 'net/http'
require 'deepmerge'

voldir = ENV.fetch('ORO_GLOBAL_VOLUME_DIR', '/opt/oro-nginx')
# rubocop:disable Security/Eval
vars = eval(File.read("#{voldir}/variables_input.rb"))
# rubocop:enable Security/Eval

vars['http']['testcookie_arg'] = SecureRandom.hex.to_s unless vars['http'].key?('testcookie_arg')
vars['http']['testcookie_refresh_encrypt_cookie_iv'] = SecureRandom.hex.to_s unless vars['http'].key?('testcookie_refresh_encrypt_cookie_iv')
vars['http']['testcookie_refresh_encrypt_cookie_key'] = SecureRandom.hex.to_s unless vars['http'].key?('testcookie_refresh_encrypt_cookie_key')

def generate_csr(common_name, organization, country, state_name, locality, san_list, path, key_path, length = 4096)
  signing_key = OpenSSL::PKey::RSA.new length.to_i

  subject = OpenSSL::X509::Name.new [
    ['CN', common_name],
    ['O', organization],
    ['C', country],
    ['ST', state_name],
    ['L', locality]
  ]

  csr = OpenSSL::X509::Request.new
  csr.version = 0
  csr.subject = subject
  csr.public_key = signing_key.public_key

  extensions = [
    OpenSSL::X509::ExtensionFactory.new.create_extension('subjectAltName', san_list)
  ]

  attribute_values = OpenSSL::ASN1::Set [OpenSSL::ASN1::Sequence(extensions)]
  [
    OpenSSL::X509::Attribute.new('extReq', attribute_values),
    OpenSSL::X509::Attribute.new('msExtReq', attribute_values)
  ].each do |attribute|
    csr.add_attribute attribute
  end

  csr.sign signing_key, OpenSSL::Digest.new('SHA256')

  File.write(key_path, signing_key.to_pem)
  File.write(path, csr.to_pem)
end

def generate_crt(csr_path, key_path, path, ca_path = nil, ca_passin = nil)
  csr = OpenSSL::X509::Request.new File.read csr_path
  ca_key = if ca_passin.is_a?(String) && !ca_passin.empty?
             OpenSSL::PKey::RSA.new(File.read(key_path), ca_passin)
           else
             OpenSSL::PKey::RSA.new(File.read(key_path))
           end

  raise 'CSR can not be verified' unless csr.verify csr.public_key
  raise 'Private key can not be verified' unless ca_key.private? && ca_key.public?

  if !ca_path.nil? && File.exist?(ca_path)
    ca_crt = OpenSSL::X509::Certificate.new(File.read(ca_path))
    raise 'CA certificate can not be verified' unless ca_crt.verify ca_key
  end

  csr_cert = OpenSSL::X509::Certificate.new
  csr_cert.serial = 0
  csr_cert.version = 2
  csr_cert.not_before = Time.now
  csr_cert.not_after = Time.now + (5 * 365 * 24 * 60 * 60) # 5 years validity

  csr_cert.subject = csr.subject
  csr_cert.public_key = csr.public_key
  csr_cert.issuer = ca_crt.subject unless ca_path.nil?

  # Отримання SAN з CSR
  san_extension = csr.attributes.find { |attr| attr.oid == 'extReq' }

  extension_factory = OpenSSL::X509::ExtensionFactory.new
  extension_factory.subject_certificate = csr_cert
  extension_factory.issuer_certificate = ca_crt unless ca_path.nil?

  csr_cert.add_extension \
    extension_factory.create_extension('basicConstraints', 'CA:FALSE')

  csr_cert.add_extension \
    extension_factory.create_extension(
      'keyUsage', 'keyEncipherment,dataEncipherment,digitalSignature'
    )

  csr_cert.add_extension \
    extension_factory.create_extension('subjectKeyIdentifier', 'hash')

  if san_extension
    san = san_extension.value.first.value.find { |ext| ext.value.first.value == 'subjectAltName' }
    san_value = san.value.last.value # Отримання значення SAN
    csr_cert.add_extension(OpenSSL::X509::Extension.new('subjectAltName', san_value))
  end

  csr_cert.sign ca_key, OpenSSL::Digest.new('SHA256')

  File.write(path, csr_cert.to_pem)
end

def check_acme(domain_name)
  puts "Detect external IP address and domain settings to provision SSL certificate for #{domain_name} domain with letsencrypt ..."

  my_ip = ''
  my_ip_valid = false
  my_domain_ip = ''
  my_domain_ip_valid = false
  result = false

  begin
    my_ip_res = Net::HTTP.get(URI.parse('http://whatismyip.akamai.com/'))
    my_ip = my_ip_res.to_s if my_ip_res.is_a?(String) && !my_ip_res.empty?
  rescue StandardError => e
    raise "Couldn't detect my externel IP address! Error: #{e}"
  end

  if my_ip.match(/^([0-9]{1,3})\.([0-9]{1,3})\.([0-9]{1,3})\.([0-9]{1,3})$/)
    my_ip_valid = true
    puts "External IP address #{my_ip} is valid"
  end

  begin
    my_domain_ip = Resolv.getaddress domain_name
  rescue StandardError => e
    puts "Couldn't detect #{domain_name} domain externel IP address! Error: #{e}"
    return result
  end

  if my_domain_ip.match(/^([0-9]{1,3})\.([0-9]{1,3})\.([0-9]{1,3})\.([0-9]{1,3})$/)
    my_domain_ip_valid = true
    puts "Domain IP address #{my_domain_ip} is valid"
  end

  if my_ip_valid && my_domain_ip_valid && my_ip == my_domain_ip
    puts "Domain name #{domain_name} matches my external IP address #{my_ip}. Using letsencrypt."
    result = true
  else
    puts "Domain name #{domain_name} isn't point to my external IP address #{my_ip}. Will proceed with self signed SSL certificate."
  end

  result
end

begin
  if vars['global'].key?('volume_dir') && File.directory?(vars['global']['volume_dir'])
    puts "Delete all files from #{vars['global']['volume_dir']} ..."
    files = Dir.glob("#{vars['global']['volume_dir']}/*")
    files -= Dir.glob("#{vars['global']['volume_dir']}/variables_input.rb")
    FileUtils.rm_rf(files)
  end
rescue StandardError => e
  raise "Couldn't delete files from #{vars['global']['volume_dir']}! Error: #{e}"
end

directories = []
directories.push(vars['constants']['etc_dir'], "#{vars['constants']['etc_dir']}/sites.d", "#{vars['constants']['etc_dir']}/sites-available", "#{vars['constants']['etc_dir']}/sites-enabled")
directories.push(vars['constants']['ssl_dir'])
directories.push(vars['constants']['var_dir'])
directories.push(vars['constants']['run_dir'])
directories.push(vars['constants']['client_body_temp_path'])
directories.push(vars['constants']['proxy_temp_path'])

begin
  puts 'Creating Nginx directories structure ...'
  FileUtils.mkdir_p(directories) unless directories.empty?
rescue StandardError => e
  raise "Couldn't create Nginx directories structure! Error: #{e}"
end

begin
  puts "Copying original Nginx configuration files from #{vars['global']['root_dir']} to #{vars['constants']['etc_dir']} ..."
  FileUtils.cp_r(Dir.glob("#{vars['global']['root_dir']}/*"), vars['constants']['etc_dir'])
  FileUtils.rm(Dir.glob("#{vars['constants']['etc_dir']}/*.default"), force: true)
rescue StandardError => e
  raise "Couldn't copy files from #{vars['global']['root_dir']} to #{vars['constants']['etc_dir']}! Error: #{e}"
end

unless vars['global']['root_ca_cert'].nil? && vars['global']['root_ca_key'].nil?
  puts "Custom Root CA certificate and key were found. Filling them into the #{vars['constants']['ssl_dir']} volume ..."
  File.write("#{vars['constants']['ssl_dir']}/ca.crt", vars['global']['root_ca_cert'])
  File.write("#{vars['constants']['ssl_dir']}/ca.key", vars['global']['root_ca_key'])
end

# Add erb template bindings
bindings = binding
bindings.local_variable_set(:vars, vars)

begin
  puts "Rendering Nginx configuration #{vars['constants']['etc_dir']}/nginx.conf ..."
  nginx_conf = ERB.new(File.read("#{vars['constants']['etc_dir']}/templates/nginx.conf.erb"), trim_mode: '-')
rescue StandardError => e
  raise "Couldn't render #{vars['constants']['etc_dir']}/nginx.conf configuration file from template! Error: #{e}"
end

if nginx_conf.is_a?(ERB) && !nginx_conf.result(bindings).empty?
  File.open("#{vars['constants']['etc_dir']}/nginx.conf", 'w+') do |f|
    f.puts(nginx_conf.result(bindings))
    File.chmod(0o440, "#{vars['constants']['etc_dir']}/nginx.conf")
    FileUtils.chown vars['global']['user'], vars['global']['group'], "#{vars['constants']['etc_dir']}/nginx.conf"
  end
end

sites = {}

# provide logic to start container with no variables input
vars['sites'].delete('domain.com') if vars['sites'].size > 1 && vars['sites'].keys.include?('domain.com')

if vars.key?('sites') && vars['sites'].is_a?(Hash)
  vars['sites'].sort.to_h.each_with_index do |(name, params), index|
    puts "Working on configuration for site #{name} ..."
    sites[name] = {} unless sites.key?(name)
    sites[name]['path'] = name.gsub(/[.-]/, '_')
    sites[name]['use_acme'] = params.fetch('acme', vars['global']['use_acme'])
    sites[name]['cert'] = params.fetch('cert', vars['global']['root_ca_cert'])
    sites[name]['key'] = params.fetch('key', vars['global']['root_ca_key'])

    sites[name]['ca_cert'] = params['ca_cert'] if params.key?('ca_cert') && params['ca_cert'].is_a?(String) && !params['ca_cert'].empty?
    sites[name]['ca_key'] = params['ca_key'] if params.key?('ca_key') && params['ca_key'].is_a?(String) && !params['ca_key'].empty?
    sites[name]['ca_passin'] = params['ca_passin'] if params.key?('ca_passin') && params['ca_passin'].is_a?(String) && !params['ca_passin'].empty?
    sites[name]['access_policy'] = params['access_policy'] if params.key?('access_policy') && params['access_policy'].is_a?(Hash) && !params['access_policy'].empty?
    sites[name]['naxsi'] = params['naxsi'] if params.key?('naxsi') && params['naxsi'].is_a?(Hash) && !params['naxsi'].empty?
    sites[name]['settings'] = params['settings'] if params.key?('settings') && params['settings'].is_a?(Hash) && !params['settings'].empty?
    sites[name]['direct'] = if params.key?('direct') && params['direct'].to_s.match(/^true|false$/)
                              params['direct'].to_s == 'true'
                            elsif vars['global'].key?('domain_direct') && vars['global']['domain_direct'].is_a?(String) && vars['global']['domain_direct'].match(/^true|false$/)
                              vars['global']['domain_direct'] == 'true'
                            else
                              false
                            end
    sites[name]['default_server'] = vars['sites'].keys[0] == name

    use_access_policy_global = vars['global']['access_policy'].any? do |_i, sub_hash|
      !sub_hash['allow'].empty? || !sub_hash['deny'].empty?
    end
    use_access_policy_site = (sites[name]['access_policy'] || {}).any? do |_i, sub_hash|
      !sub_hash['allow'].empty? || !sub_hash['deny'].empty?
    end
    sites[name]['use_access_policy'] = use_access_policy_global || use_access_policy_site
    sites[name]['index'] = index

    if sites[name]['direct']
      sites[name]['server_name'] = "#{name} www.#{name}"
      sites[name]['alt_names'] = "DNS:#{name},DNS:www.#{name}"
      sites[name]['acme_list'] = "-d #{name} -d www.#{name}"
    else
      sites[name]['server_name'] = "#{name} *.#{name}"
      sites[name]['alt_names'] = "DNS:#{name},DNS:*.#{name}"
      sites[name]['acme_list'] = "-d #{name} -d *.#{name}"
    end

    # Add erb template bindings
    bindings.local_variable_set(:name, name)
    bindings.local_variable_set(:sites, sites)

    if (sites[name].key?('cert') && sites[name]['cert'].is_a?(String) && !sites[name]['cert'].empty?) &&
       (sites[name].key?('key') && sites[name]['key'].is_a?(String) && !sites[name]['key'].empty?)
      File.write("#{vars['constants']['ssl_dir']}/#{sites[name]['path']}.crt", sites[name]['cert'])
      File.write("#{vars['constants']['ssl_dir']}/#{sites[name]['path']}.key", sites[name]['key'])
    elsif (sites[name].key?('ca_cert') && sites[name]['ca_cert'].is_a?(String) && !sites[name]['ca_cert'].empty?) &&
          (sites[name].key?('ca_key') && sites[name]['ca_key'].is_a?(String) && !sites[name]['ca_key'].empty?)
      File.write("#{vars['constants']['ssl_dir']}/#{sites[name]['path']}_ca.crt", sites[name]['ca_cert'])
      File.write("#{vars['constants']['ssl_dir']}/#{sites[name]['path']}_ca.key", sites[name]['ca_key'])
      begin
        puts "Generate CSR request #{vars['constants']['ssl_dir']}/#{sites[name]['path']}.csr for domain #{name} ..."
        generate_csr(
          name,
          'OroInc', 'US', 'California', 'Los Angeles',
          sites[name]['alt_names'],
          "#{vars['constants']['ssl_dir']}/#{sites[name]['path']}.csr",
          "#{vars['constants']['ssl_dir']}/#{sites[name]['path']}.key"
        )
      rescue StandardError => e
        raise "Couldn't generate CSR request for domain #{name}! Error: #{e}"
      end

      begin
        puts "Create server certificate #{vars['constants']['ssl_dir']}/#{sites[name]['path']}.crt from CSR request for domain #{name} ..."
        options = [
          "#{vars['constants']['ssl_dir']}/#{sites[name]['path']}.csr",
          "#{vars['constants']['ssl_dir']}/#{sites[name]['path']}_ca.key",
          "#{vars['constants']['ssl_dir']}/#{sites[name]['path']}.crt",
          "#{vars['constants']['ssl_dir']}/#{sites[name]['path']}_ca.crt"
        ]
        options.append(vars['global']['root_ca_passin']) if vars['global'].key?('root_ca_passin') && vars['global']['root_ca_passin'].is_a?(String) && !vars['global']['root_ca_passin'].empty?
        generate_crt(*options)
      rescue StandardError => e
        raise "Couldn't sign CSR request for domain #{name}! Error: #{e}"
      end

      begin
        puts "Create server certificate #{vars['constants']['ssl_dir']}/#{sites[name]['path']}.crt from CSR request for domain #{name} ..."
        generate_crt(
          "#{vars['constants']['ssl_dir']}/#{sites[name]['path']}.csr",
          "#{vars['constants']['ssl_dir']}/#{sites[name]['path']}_ca.crt",
          "#{vars['constants']['ssl_dir']}/#{sites[name]['path']}_ca.key"
        )
      rescue StandardError => e
        raise "Couldn't sign CSR request for domain #{name}! Error: #{e}"
      end
    elsif (vars['global'].key?('root_ca_cert') && vars['global']['root_ca_cert'].is_a?(String) && !vars['global']['root_ca_cert'].empty?) &&
          (vars['global'].key?('root_ca_key') && vars['global']['root_ca_key'].is_a?(String) && !vars['global']['root_ca_key'].empty?)
      begin
        puts "Generate CSR request #{vars['constants']['ssl_dir']}/#{sites[name]['path']}.csr for domain #{name} ..."
        generate_csr(
          name,
          'OroInc', 'US', 'California', 'Los Angeles',
          sites[name]['alt_names'],
          "#{vars['constants']['ssl_dir']}/#{sites[name]['path']}.csr",
          "#{vars['constants']['ssl_dir']}/#{sites[name]['path']}.key"
        )
      rescue StandardError => e
        raise "Couldn't generate CSR request for domain #{name}! Error: #{e}"
      end

      begin
        puts "Create server certificate #{vars['constants']['ssl_dir']}/#{sites[name]['path']}.crt from CSR request for domain #{name} ..."
        options = [
          "#{vars['constants']['ssl_dir']}/#{sites[name]['path']}.csr",
          "#{vars['constants']['ssl_dir']}/ca.key",
          "#{vars['constants']['ssl_dir']}/#{sites[name]['path']}.crt",
          "#{vars['constants']['ssl_dir']}/ca.crt"
        ]
        options.append(vars['global']['root_ca_passin']) if vars['global'].key?('root_ca_passin') && vars['global']['root_ca_passin'].is_a?(String) && !vars['global']['root_ca_passin'].empty?
        generate_crt(*options)
      rescue StandardError => e
        raise "Couldn't sign CSR request for domain #{name}! Error: #{e}"
      end
    else
      acme_valid = check_acme(name)

      use_acme = if sites[name].key?('use_acme') && %w[true unset].include?(sites[name]['use_acme'])
                   true
                 else
                   vars['global'].key?('use_acme') && %w[true unset].include?(vars['global']['use_acme'])
                 end

      if use_acme && acme_valid
        # Add erb template bindings
        bindings.local_variable_set(:use_acme, true)

        acme_valid_www = check_acme("www.#{name}")
        sites[name]['server_name'] = "#{name} www.#{name}"
        sites[name]['alt_names'] = if acme_valid_www.to_s == 'true'
                                     "DNS:#{name},DNS:www.#{name}"
                                   else
                                     "DNS:#{name}"
                                   end
        sites[name]['acme_list'] = if acme_valid_www.to_s == 'true'
                                     "-d #{name} -d www.#{name}"
                                   else
                                     "-d #{name}"
                                   end

        puts "Start Nginx server to provision SSL certificate for #{name} domain ..."
        acme_conf = ERB.new(File.read('/opt/oro-nginx/etc/templates/acme.conf.erb'), trim_mode: '-')

        if acme_conf.is_a?(ERB) && !acme_conf.result(bindings).empty?
          File.open("#{vars['constants']['etc_dir']}/sites-available/acme-#{sites[name]['path']}.conf", 'w+') do |f|
            f.puts(acme_conf.result(bindings))
            File.chmod(0o440, "#{vars['constants']['etc_dir']}/sites-available/acme-#{sites[name]['path']}.conf")
            FileUtils.chown vars['global']['user'], vars['global']['group'], "#{vars['constants']['etc_dir']}/sites-available/acme-#{sites[name]['path']}.conf"
            File.symlink("#{vars['constants']['etc_dir']}/sites-available/acme-#{sites[name]['path']}.conf", "#{vars['constants']['etc_dir']}/sites-enabled/acme-#{sites[name]['path']}.conf")
          end
        end

        begin
          check_config = system("/usr/sbin/nginx -tq -c #{vars['constants']['etc_dir']}/nginx.conf", exception: true)
        rescue StandardError => e
          raise "Nginx configuration acme-#{sites[name]['path']}.conf is invalid for domain #{name}! Error: #{e}"
        end

        start_nginx = spawn("/usr/sbin/nginx -c '#{vars['constants']['etc_dir']}/nginx.conf' -g 'daemon off;'")

        acme_setup = "/acme_setup '#{vars['constants']['acme_dir']}' '#{vars['constants']['etc_dir']}'
          '#{vars['global']['public_dir']}' '#{vars['constants']['ssl_dir']}' '#{sites[name]['acme_list']}' '#{sites[name]['path']}'"
        puts "Running acme_setup with the next arguments: '#{vars['constants']['acme_dir']}'
          '#{vars['constants']['etc_dir']}' '#{vars['global']['public_dir']}'
          '#{vars['constants']['ssl_dir']}' '#{sites[name]['acme_list']}' '#{sites[name]['path']}'"

        begin
          acme_setup = system(
            "/acme_setup '#{vars['constants']['acme_dir']}' '#{vars['constants']['etc_dir']}'
            '#{vars['global']['public_dir']}' '#{vars['constants']['ssl_dir']}'
            '#{sites[name]['acme_list']}' '#{sites[name]['path']}'", exception: true
          )
        rescue StandardError => e
          Process.kill('KILL', start_nginx)
          raise "Couldn't complete ACME setup for domain #{name}! Error: #{e}"
        end

        puts acme_setup

        begin
          Process.kill(:INT, start_nginx)
        rescue Errno::ESRCH
          puts "process #{start_nginx} already exited!"
        end

        FileUtils.rm_f("#{vars['constants']['etc_dir']}/sites-enabled/acme-#{sites[name]['path']}.conf")
        FileUtils.rm_f("#{vars['constants']['etc_dir']}/sites-available/acme-#{sites[name]['path']}.conf")
      else
        begin
          puts "Generate CSR request #{vars['constants']['ssl_dir']}/#{sites[name]['path']}.csr for domain #{name} ..."
          generate_csr(
            name,
            'OroInc', 'US', 'California', 'Los Angeles',
            sites[name]['alt_names'],
            "#{vars['constants']['ssl_dir']}/#{sites[name]['path']}.csr",
            "#{vars['constants']['ssl_dir']}/#{sites[name]['path']}.key"
          )
        rescue StandardError => e
          raise "Couldn't generate CSR request for domain #{name}! Error: #{e}"
        end

        begin
          puts "Create server certificate #{vars['constants']['ssl_dir']}/#{sites[name]['path']}.crt from CSR request for domain #{name} ..."
          generate_crt(
            "#{vars['constants']['ssl_dir']}/#{sites[name]['path']}.csr",
            "#{vars['constants']['ssl_dir']}/#{sites[name]['path']}.key",
            "#{vars['constants']['ssl_dir']}/#{sites[name]['path']}.crt"
          )
        rescue StandardError => e
          raise "Couldn't sign CSR request for domain #{name}! Error: #{e}"
        end
      end
    end

    unless File.exist?("#{vars['constants']['ssl_dir']}/#{sites[name]['path']}.crt") || File.exist?("#{vars['constants']['ssl_dir']}/#{sites[name]['path']}.key")
      raise "Somehing went wrong. Coudn't find certificate or key after provisioning for #{name} domain!"
    end

    puts "SSL Certificate provisioning completed successfully for #{name} domain."

    # UPSTREAM conf context: server
    if vars['global']['use_upstream'].to_s == 'true'
      begin
        puts "Rendering Nginx configuration #{vars['constants']['etc_dir']}/conf.d/upstream_app.conf ..."
        upstream_app_conf = ERB.new(File.read("#{vars['constants']['etc_dir']}/templates/upstream_app.conf.erb"), trim_mode: '-')
      rescue StandardError => e
        raise "Couldn't render #{vars['constants']['etc_dir']}/conf.d/upstream_app.conf configuration file from template! Error: #{e}"
      end

      if upstream_app_conf.is_a?(ERB) && !upstream_app_conf.result(bindings).empty?
        File.open("#{vars['constants']['etc_dir']}/conf.d/upstream_app.conf", 'w+') do |f|
          f.puts(upstream_app_conf.result(bindings))
          File.chmod(0o440, "#{vars['constants']['etc_dir']}/conf.d/upstream_app.conf")
          FileUtils.chown vars['global']['user'], vars['global']['group'], "#{vars['constants']['etc_dir']}/conf.d/upstream_app.conf"
        end
      end
    end

    # BLOCKLIST conf context: server
    if sites[name]['use_access_policy']
      begin
        puts "Rendering Nginx configuration #{vars['constants']['etc_dir']}/conf.d/blocklist_#{sites[name]['path']}.conf ..."
        blocklist_conf = ERB.new(File.read("#{vars['constants']['etc_dir']}/templates/blocklist.conf.erb"), trim_mode: '-')
      rescue StandardError => e
        raise "Couldn't render #{vars['constants']['etc_dir']}/conf.d/blocklist_#{sites[name]['path']}.conf configuration file from template! Error: #{e}"
      end

      if blocklist_conf.is_a?(ERB) && !blocklist_conf.result(bindings).empty?
        File.open("#{vars['constants']['etc_dir']}/conf.d/blocklist_#{sites[name]['path']}.conf", 'w+') do |f|
          f.puts(blocklist_conf.result(bindings))
          File.chmod(0o440, "#{vars['constants']['etc_dir']}/conf.d/blocklist_#{sites[name]['path']}.conf")
          FileUtils.chown vars['global']['user'], vars['global']['group'], "#{vars['constants']['etc_dir']}/conf.d/blocklist_#{sites[name]['path']}.conf"
        end
      end
    end

    # Add NAXSI WAF configuration context: location
    final_naxsi = vars['server']['naxsi'].deep_merge(sites[name]['naxsi']&.compact || {})
    final_naxsi['basic_rules'] = sites.dig(name, 'naxsi', 'basic_rules')&.compact || [] if final_naxsi['merge_behaviour']['basic_rules'].to_s == 'false'
    final_naxsi['basic_rules_wl'] = sites.dig(name, 'naxsi', 'basic_rules_wl')&.compact || [] if final_naxsi['merge_behaviour']['basic_rules_wl'].to_s == 'false'
    final_naxsi['check_rules'] = sites.dig(name, 'naxsi', 'check_rules')&.compact || [] if final_naxsi['merge_behaviour']['check_rules'].to_s == 'false'
    naxsi_config = {
      'basic' => {
        'data' => final_naxsi['basic_rules'],
        'file' => "#{vars['constants']['etc_dir']}/naxsi_rules_basic_#{sites[name]['path']}.conf",
        'erb' => "#{vars['constants']['etc_dir']}/templates/naxsi_rules.conf.erb"
      },
      'basic_wl' => {
        'data' => final_naxsi['basic_rules_wl'],
        'file' => "#{vars['constants']['etc_dir']}/naxsi_rules_basic_wl_#{sites[name]['path']}.conf",
        'erb' => "#{vars['constants']['etc_dir']}/templates/naxsi_rules.conf.erb"
      },
      'check' => {
        'data' => final_naxsi['check_rules'],
        'file' => "#{vars['constants']['etc_dir']}/naxsi_rules_check_#{sites[name]['path']}.conf",
        'erb' => "#{vars['constants']['etc_dir']}/templates/naxsi_rules.conf.erb"
      }
    }

    bindings.local_variable_set(:naxsi_merged, final_naxsi)

    naxsi_config.each_value do |param|
      # comments on this! allow to create appropriate file even if param['data'] is empty. condition in erb will handle it
      # next unless param['data'].is_a?(Array) && !param['data'].empty? && !param['data'].nil?
      naxsi_bindings = binding
      naxsi_bindings.local_variable_set(:rules, param['data'])

      begin
        puts "Rendering Nginx naxsi configuration #{param['file']} ..."
        rules_conf = ERB.new(File.read(param['erb']), trim_mode: '-')
      rescue StandardError => e
        raise "Couldn't render #{param['file']} configuration file from template! Error: #{e}"
      end

      next unless rules_conf.is_a?(ERB) && !rules_conf.result(naxsi_bindings).empty?

      File.open(param['file'], 'w+') do |f|
        f.puts(rules_conf.result(naxsi_bindings))
        File.chmod(0o440, param['file'])
        FileUtils.chown vars['global']['user'], vars['global']['group'], param['file']
      end
    end

    # Sites conf
    begin
      puts "Rendering Nginx configuration #{vars['constants']['etc_dir']}/sites-available/#{sites[name]['path']}.conf ..."
      domain_conf = ERB.new(File.read("#{vars['constants']['etc_dir']}/templates/domain.conf.erb"), trim_mode: '-')
    rescue StandardError => e
      raise "Couldn't render #{vars['constants']['etc_dir']}/sites-available/#{sites[name]['path']}.conf configuration file from template! Error: #{e}"
    end

    next unless domain_conf.is_a?(ERB) && !domain_conf.result(bindings).empty?

    File.open("#{vars['constants']['etc_dir']}/sites-available/#{sites[name]['path']}.conf", 'w+') do |f|
      f.puts(domain_conf.result(bindings))
      File.chmod(0o440, "#{vars['constants']['etc_dir']}/sites-available/#{sites[name]['path']}.conf")
      FileUtils.chown vars['global']['user'], vars['global']['group'], "#{vars['constants']['etc_dir']}/sites-available/#{sites[name]['path']}.conf"
      File.symlink("#{vars['constants']['etc_dir']}/sites-available/#{sites[name]['path']}.conf", "#{vars['constants']['etc_dir']}/sites-enabled/#{sites[name]['path']}.conf")
    end
  end
end

# Secheaders conf
begin
  puts "Rendering Nginx configuration #{vars['constants']['etc_dir']}/conf.d/secheaders.conf ..."
  secheaders_conf = ERB.new(File.read("#{vars['constants']['etc_dir']}/templates/secheaders.conf.erb"), trim_mode: '-')
rescue StandardError => e
  raise "Couldn't render #{vars['constants']['etc_dir']}/conf.d/secheaders.conf configuration file from template! Error: #{e}"
end

if secheaders_conf.is_a?(ERB) && !secheaders_conf.result(bindings).empty?
  File.open("#{vars['constants']['etc_dir']}/conf.d/secheaders.conf", 'w+') do |f|
    f.puts(secheaders_conf.result(bindings))
    File.chmod(0o440, "#{vars['constants']['etc_dir']}/conf.d/secheaders.conf")
    FileUtils.chown vars['global']['user'], vars['global']['group'], "#{vars['constants']['etc_dir']}/conf.d/secheaders.conf"
  end
end

# Add Naxsi WAF configuration context: http
naxsi_config = {
  'main' => {
    'data' => vars['server']['naxsi']['main_rules'],
    'file' => "#{vars['constants']['etc_dir']}/naxsi_rules_main.conf",
    'erb' => "#{vars['constants']['etc_dir']}/templates/naxsi_rules.conf.erb"
  },
  'main_wl' => {
    'data' => vars['server']['naxsi']['main_rules_wl'],
    'file' => "#{vars['constants']['etc_dir']}/naxsi_rules_main_wl.conf",
    'erb' => "#{vars['constants']['etc_dir']}/templates/naxsi_rules.conf.erb"
  }
}

naxsi_config.each_value do |params|
  next unless params['data'].is_a?(Array) && !params['data'].empty? && !params['data'].nil?

  naxsi_bindings = binding
  naxsi_bindings.local_variable_set(:rules, params['data'])

  begin
    puts "Rendering Nginx naxsi configuration #{params['file']} ..."
    rules_conf = ERB.new(File.read(params['erb']), trim_mode: '-')
  rescue StandardError => e
    raise "Couldn't render #{params['file']} configuration file from template! Error: #{e}"
  end

  next unless rules_conf.is_a?(ERB) && !rules_conf.result(naxsi_bindings).empty?

  File.open(params['file'], 'w+') do |f|
    f.puts(rules_conf.result(naxsi_bindings))
    File.chmod(0o440, params['file'])
    FileUtils.chown vars['global']['user'], vars['global']['group'], params['file']
  end
end
