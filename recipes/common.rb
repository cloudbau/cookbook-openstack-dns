# encoding: UTF-8
#
# Cookbook Name:: openstack-dns
# Recipe:: common
#
# Copyright 2017, x-ion Gmbh
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
#     http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.
#

class ::Chef::Recipe # rubocop:disable Documentation
  include ::Openstack
end

if node['openstack']['dns']['syslog']['use']
  include_recipe 'openstack-common::logging'
end

platform_options = node['openstack']['dns']['platform']

apt_update ''

platform_options['designate_packages'].each do |pkg|
  package pkg do
    options platform_options['package_overrides']

    action :upgrade
  end
end

db_type = node['openstack']['db']['dns']['service_type']
node['openstack']['db']['python_packages'][db_type].each do |pkg|
  package pkg do
    action :upgrade
  end
end

if node['openstack']['mq']['service_type'] == 'rabbit'
  node.default['openstack']['dns']['conf_secrets']['DEFAULT']['transport_url'] = rabbit_transport_url 'dns'
  # Note(jh): Workaround for https://bugs.launchpad.net/designate/+bug/1673403
  # Stolen from rabbit_transport_url() in openstack-common/libraries/endpoints.rb
  mq_user = node['openstack']['mq']['dns']['rabbit']['userid']
  node.default['openstack']['dns']['conf_secrets']['oslo_messaging_rabbit']['rabbit_userid'] = mq_user
  node.default['openstack']['dns']['conf_secrets']['oslo_messaging_rabbit']['rabbit_password'] = get_password 'user', mq_user
  node.default['openstack']['dns']['conf_secrets']['oslo_messaging_rabbit']['rabbit_virtual_host'] = node['openstack']['mq']['vhost']
  mq_port = node['openstack']['endpoints']['mq']['port']
  url = ''
  if node['openstack']['mq']['cluster']
    node['openstack']['mq']['servers'].each do |server|
      url += "#{server}:#{mq_port}"
      url += ',' unless node['openstack']['mq']['servers'].last == server
    end
  else
    bind_mq_address = bind_address node['openstack']['bind_service']['mq']
    url += "#{bind_mq_address}:#{mq_port}"
  end
  node.default['openstack']['dns']['conf_secrets']['oslo_messaging_rabbit']['rabbit_hosts'] = url
end

db_user = node['openstack']['db']['dns']['username']
db_pass = get_password 'db', 'designate'

identity_endpoint = internal_endpoint 'identity'

bind_services = node['openstack']['bind_service']['all']
api_bind = bind_services['dns-api']

auth_uri = auth_uri_transform identity_endpoint.to_s, node['openstack']['dns']['api']['auth']['version']

# define attributes that are needed in designate.conf
node.default['openstack']['dns']['conf'].tap do |conf|
  conf['service:api']['api_host'] = bind_address api_bind
  conf['service:api']['api_port'] = api_bind.port
  conf['keystone_authtoken']['auth_url'] = auth_uri
end

# define secrets that are needed in designate.conf
node.default['openstack']['dns']['conf_secrets'].tap do |conf_secrets|
  conf_secrets['storage:sqlalchemy']['connection'] =
    db_uri('dns', db_user, db_pass)
  conf_secrets['keystone_authtoken']['password'] =
    get_password 'service', 'openstack-dns'
end

# merge all config options and secrets to be used in designate.conf
designate_conf_options = merge_config_options 'dns'

directory '/etc/designate' do
  owner node['openstack']['dns']['user']
  group node['openstack']['dns']['group']
  mode 00750
  action :create
end

template '/etc/designate/designate.conf' do
  source 'openstack-service.conf.erb'
  cookbook 'openstack-common'
  owner node['openstack']['dns']['user']
  group node['openstack']['dns']['group']
  mode 00640
  variables(
    service_config: designate_conf_options
  )
end

template '/etc/designate/pools.yaml' do
  source 'pools.yaml.erb'
  owner node['openstack']['dns']['user']
  group node['openstack']['dns']['group']
  mode 00644
end

execute 'designate-manage database sync' do
  user node['openstack']['dns']['user']
  group node['openstack']['dns']['group']
  command 'designate-manage database sync'
  action :run
end

execute 'designate-manage pool update' do
  user node['openstack']['dns']['user']
  group node['openstack']['dns']['group']
  command 'designate-manage pool update'
  action :nothing
  subscribes :run, 'template[/etc/designate/pools.yaml]'
end
