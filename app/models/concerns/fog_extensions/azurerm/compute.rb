module FogExtensions
  module AzureRM
    module Compute
      extend ActiveSupport::Concern

      def list_available_sizes(location)
        sizes = []
        @compute_mgmt_client.virtual_machine_sizes.list(location).value().each do |vmsize|
          sizes << vmsize.name
        end
        sizes
      end

      def define_managed_storage_profile(vm_name, vhd_path, os_disk_caching, platform, os_disk_size, premium_os_disk, data_disks = nil)
        storage_profile = Azure::ARM::Compute::Models::StorageProfile.new
        os_disk = Azure::ARM::Compute::Models::OSDisk.new
        image_ref = Azure::ARM::Compute::Models::ImageReference.new
        managed_disk_params = Azure::ARM::Compute::Models::ManagedDiskParameters.new

        # Not actually the VHD path, instead is managed image ID
        image_ref.id = vhd_path

        os_disk.name = "#{vm_name}-osdisk"
        os_disk.os_type = (platform == 'Windows') ?
            Azure::ARM::Compute::Models::OperatingSystemTypes::Windows :
            Azure::ARM::Compute::Models::OperatingSystemTypes::Linux
        os_disk.create_option = Azure::ARM::Compute::Models::DiskCreateOptionTypes::FromImage
        os_disk.caching = unless os_disk_caching.nil?
                            case os_disk_caching
                              when 'None'
                                Azure::ARM::Compute::Models::CachingTypes::None
                              when 'ReadOnly'
                                Azure::ARM::Compute::Models::CachingTypes::ReadOnly
                              when 'ReadWrite'
                                Azure::ARM::Compute::Models::CachingTypes::ReadWrite
                            end
                          end
        os_disk.disk_size_gb = os_disk_size
        managed_disk_params.storage_account_type = (premium_os_disk == 'true') ?
            Azure::ARM::Compute::Models::StorageAccountTypes::PremiumLRS :
            Azure::ARM::Compute::Models::StorageAccountTypes::StandardLRS
        os_disk.managed_disk = managed_disk_params
        storage_profile.os_disk = os_disk
        storage_profile.image_reference = image_ref

        # Create data disks
        unless data_disks.nil?
          disks = []
          disk_count = 0
          data_disks.each do |disk_num, attrs|
            managed_data_disk = Azure::ARM::Compute::Models::ManagedDiskParameters.new
            managed_data_disk.storage_account_type = (attrs[:account_type] == 'true') ?
              Azure::ARM::Compute::Models::StorageAccountTypes::PremiumLRS :
              Azure::ARM::Compute::Models::StorageAccountTypes::StandardLRS
            disk = Azure::ARM::Compute::Models::DataDisk.new
            disk.name = "#{vm_name}-disk#{disk_count}"
            disk.caching = Azure::ARM::Compute::Models::CachingTypes::None
            disk.disk_size_gb = attrs[:disk_size_gb]
            disk.create_option = Azure::ARM::Compute::Models::DiskCreateOption::Empty
            disk.lun = disk_count + 1
            disk.managed_disk = managed_data_disk
            disk_count += 1
            disks << disk
          end
          storage_profile.data_disks = disks
        end
        storage_profile
      end

      def create_managed_virtual_machine(vm_hash, async = false)
        msg = "Creating Virtual Machine #{vm_hash[:name]} in Resource Group #{vm_hash[:resource_group]}."
        Fog::Logger.debug msg
        virtual_machine = Azure::ARM::Compute::Models::VirtualMachine.new

        unless vm_hash[:availability_set_id].nil?
          sub_resource = MsRestAzure::SubResource.new
          sub_resource.id = vm_hash[:availability_set_id]
          virtual_machine.availability_set = sub_resource
        end

        string_data = vm_hash[:custom_data]
        string_data = WHITE_SPACE if string_data.nil?
        encoded_data = Base64.strict_encode64(string_data)
        virtual_machine.hardware_profile = define_hardware_profile(vm_hash[:vm_size])
        virtual_machine.storage_profile = define_managed_storage_profile(vm_hash[:name],
                                                                 vm_hash[:vhd_path],
                                                                 vm_hash[:os_disk_caching],
                                                                 vm_hash[:platform],
                                                                 vm_hash[:os_disk_size],
                                                                 vm_hash[:premium_os_disk],
                                                                 vm_hash[:data_disks])
        virtual_machine.os_profile = if vm_hash[:platform].casecmp(WINDOWS).zero?
                                       define_windows_os_profile(vm_hash[:name],
                                                                 vm_hash[:username],
                                                                 vm_hash[:password],
                                                                 vm_hash[:provision_vm_agent],
                                                                 vm_hash[:enable_automatic_updates],
                                                                 encoded_data)
                                     else
                                       define_linux_os_profile(vm_hash[:name],
                                                               vm_hash[:username],
                                                               vm_hash[:password],
                                                               vm_hash[:disable_password_authentication],
                                                               vm_hash[:ssh_key_path],
                                                               vm_hash[:ssh_key_data],
                                                               encoded_data)
                                     end
        virtual_machine.network_profile = define_network_profile(vm_hash[:network_interface_card_ids])
        virtual_machine.location = vm_hash[:location]
        begin
          response = if async
                       @compute_mgmt_client.virtual_machines.create_or_update_async(vm_hash[:resource_group], vm_hash[:name], virtual_machine)
                     else
                       @compute_mgmt_client.virtual_machines.create_or_update(vm_hash[:resource_group], vm_hash[:name], virtual_machine)
                     end
        rescue MsRestAzure::AzureOperationError => e
          raise_azure_exception(e, msg)
        end
        Fog::Logger.debug "Virtual Machine #{vm_hash[:name]} Created Successfully." unless async
        response
      end
    end
  end
end