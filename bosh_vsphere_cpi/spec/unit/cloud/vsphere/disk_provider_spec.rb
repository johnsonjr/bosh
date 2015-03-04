require 'spec_helper'

module VSphereCloud
  describe DiskProvider do
    subject(:disk_provider) do
      described_class.new(
        virtual_disk_manager,
        datacenter,
        resources,
        'fake-disk-path',
        client,
        logger
      )
    end

    let(:virtual_disk_manager) { instance_double('VimSdk::Vim::VirtualDiskManager') }
    let(:datacenter) do
      instance_double('VSphereCloud::Resources::Datacenter', name: 'fake-datacenter-name', mob: datacenter_mob)
    end
    let(:datacenter_mob) { instance_double('VimSdk::Vim::Datacenter') }
    let(:resources) { instance_double('VSphereCloud::Resources') }
    let(:client) { instance_double('VSphereCloud::Client', wait_for_task: nil) }
    let(:logger) { double(:logger, info: nil, debug: nil) }

    let(:datastore) do
      Resources::Datastore.new(
        'name' => 'fake-datastore',
        'summary.freeSpace' => 1024,
        'summary.capacity' => 2048,
      )
    end

    describe '#create' do
      before do
        allow(SecureRandom).to receive(:uuid).and_return('cid')
        cluster = instance_double(VSphereCloud::Resources::Cluster)
        allow(datacenter).to receive(:pick_persistent_datastore).with(24).and_return(datastore)
        allow(virtual_disk_manager).to receive(:create_virtual_disk)
        allow(client).to receive(:create_datastore_folder)
      end

      let(:datastore) { instance_double('VSphereCloud::Resources::Datastore', name: 'fake-datastore-name') }

      it 'creates disk using VirtualDiskManager' do
        expect(virtual_disk_manager).to receive(:create_virtual_disk) do |path, dc, spec|
          expect(path).to eq('[fake-datastore-name] fake-disk-path/disk-cid.vmdk')
          expect(dc).to eq(datacenter_mob)
          expect(spec.disk_type).to eq('preallocated')
          expect(spec.capacity_kb).to eq(24576)
          expect(spec.adapter_type).to eq('lsiLogic')
        end

        disk = disk_provider.create(24)
        expect(disk.cid).to eq('disk-cid')
        expect(disk.size_in_mb).to eq(24)
        expect(disk.path).to eq('[fake-datastore-name] fake-disk-path/disk-cid.vmdk')
        expect(disk.datastore).to eq(datastore)
      end

      it 'creates parent folder' do
        expect(client).to receive(:create_datastore_folder).with('[fake-datastore-name] fake-disk-path', datacenter_mob)
        disk_provider.create(24)
      end

      context 'when there are no datastores on host cluster that can fit disk size' do
        before do
          cluster = instance_double(VSphereCloud::Resources::Cluster)
          allow(datacenter).to receive(:pick_persistent_datastore).with(24).and_return(nil)
        end

        it 'raises an error' do
          expect {
            disk_provider.create(24)
          }.to raise_error Bosh::Clouds::NoDiskSpace
        end
      end
    end

    describe '#find_and_move' do
      let(:cluster) { instance_double('VSphereCloud::Resources::Cluster', name: 'fake-cluster-name') }

      context 'when disk exists' do
        let(:cylinders) { 2097152 }
        before do
          allow(virtual_disk_manager).to receive(:query_virtual_disk_geometry).
            with('[fake-datastore] fake-disk-path/disk-cid.vmdk', datacenter_mob).
            and_return(
              double(:host_disk_dimensions_chs, cylinder: cylinders, head: 4, sector: 8)
            )

          allow(datacenter).to receive(:persistent_datastores).and_return(
            {'fake-datastore' => datastore}
          )
        end

        context 'when disk is in one of accessible datastores' do
          let(:accessible_datastores) { ['fake-datastore'] }

          context 'when disk is in persistent datastores' do
            it 'returns disk' do
              disk = disk_provider.find_and_move('disk-cid', cluster, 'fake-datacenter', accessible_datastores)
              expect(disk.cid).to eq('disk-cid')
              expect(disk.size_in_mb).to eq(128)
              expect(disk.datastore).to eq(datastore)
              expect(disk.path).to eq('[fake-datastore] fake-disk-path/disk-cid.vmdk')
            end
          end

          context 'when size in kb is not an even number of mb' do
            let(:cylinders) { 2041000 }

            it 'rounds up to an even number of mb' do
              disk = disk_provider.find_and_move('disk-cid', cluster, 'fake-datacenter', accessible_datastores)
              expect(disk.size_in_mb).to eq(125)
            end
          end
        end

        context 'when disk is not in one of the accessible datastores' do
          let(:accessible_datastores) { ['fake-host-datastore'] }

          let(:destination_datastore) { Resources::Datastore.new('name' => destination_datastore_name) }
          let(:destination_datastore_name) { 'fake-host-datastore' }
          before { allow(resources).to receive(:pick_persistent_datastore_in_cluster).and_return(destination_datastore) }

          it 'moves disk' do
            expect(client).to receive(:move_disk).with(
              'fake-host-datacenter',
              '[fake-datastore] fake-disk-path/disk-cid.vmdk',
              'fake-host-datacenter',
              '[fake-host-datastore] fake-disk-path/disk-cid.vmdk'
            )
            expect(client).to receive(:create_datastore_folder).with('[fake-host-datastore] fake-disk-path', datacenter_mob)
            disk = disk_provider.find_and_move('disk-cid', cluster, 'fake-host-datacenter', accessible_datastores)
            expect(disk.cid).to eq('disk-cid')
            expect(disk.size_in_mb).to eq(128)
            expect(disk.datastore).to eq(destination_datastore)
            expect(disk.path).to eq('[fake-host-datastore] fake-disk-path/disk-cid.vmdk')
          end

          context 'when datastore that fits disk cannot be found' do
            before { allow(resources).to receive(:pick_persistent_datastore_in_cluster).and_return(nil) }

            it 'raises an error' do
              expect {
                disk_provider.find_and_move('disk-cid', cluster, 'fake-host-datacenter', accessible_datastores)
              }.to raise_error Bosh::Clouds::NoDiskSpace
            end
          end

          context 'when picked datastore is not one of the accessible datastores' do
            let(:destination_datastore_name) { 'non-accessible-datastore' }

            it 'raises an error' do
              expect {
                disk_provider.find_and_move('disk-cid', cluster, 'fake-host-datacenter', accessible_datastores)
              }.to raise_error "Datastore 'non-accessible-datastore' is not accessible to cluster 'fake-cluster-name'"
            end
          end
        end
      end

      context 'when disk does not exist' do
        before do
          allow(datacenter).to receive(:persistent_datastores).and_return({})
          allow(virtual_disk_manager).to receive(:query_virtual_disk_geometry).
            with('[fake-datastore] fake-disk-path/disk-cid.vmdk', datacenter_mob).
            and_raise(VimSdk::SoapError.new('fake-message', 'fake-fault'))
        end

        it 'raises DiskNotFound' do
          expect {
            disk_provider.find_and_move('disk-cid', cluster, 'fake-datacenter', ['fake-datastore'])
          }.to raise_error Bosh::Clouds::DiskNotFound
        end
      end
    end

    describe '#find' do
      before do
        allow(datacenter).to receive(:persistent_datastores).and_return({'fake-datastore' => datastore})
      end

      context 'when disk exists' do
        before do
          allow(virtual_disk_manager).to receive(:query_virtual_disk_geometry).
            with('[fake-datastore] fake-disk-path/disk-cid.vmdk', datacenter_mob).
            and_return(
            double(:host_disk_dimensions_chs, cylinder: 2097152, head: 4, sector: 8)
          )
        end

        it 'returns disk' do
          disk = disk_provider.find('disk-cid')
          expect(disk.cid).to eq('disk-cid')
          expect(disk.size_in_mb).to eq(128)
          expect(disk.datastore).to eq(datastore)
          expect(disk.path).to eq('[fake-datastore] fake-disk-path/disk-cid.vmdk')
        end
      end

      context 'when disk does not exist' do
        before do
          allow(virtual_disk_manager).to receive(:query_virtual_disk_geometry).
            with('[fake-datastore] fake-disk-path/disk-cid.vmdk', datacenter_mob).
            and_raise(VimSdk::SoapError.new('fake-message', 'fake-fault'))
        end

        it 'raises DiskNotFound' do
          expect {
            disk_provider.find('disk-cid')
          }.to raise_error Bosh::Clouds::DiskNotFound
        end
      end
    end
  end
end
