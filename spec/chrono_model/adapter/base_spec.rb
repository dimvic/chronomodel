# frozen_string_literal: true

require 'spec_helper'
require 'support/adapter/structure'

RSpec.describe ChronoModel::Adapter do
  include ChronoTest::Adapter::Structure

  subject { adapter }

  it { is_expected.to be_a(described_class) }

  describe '.adapter_name' do
    subject { adapter.adapter_name }

    it { is_expected.to eq 'PostgreSQL' }
  end

  describe '.chrono_supported?' do
    subject { adapter.chrono_supported? }

    before { allow(adapter).to receive(:postgresql_version).and_return(postgres_version) }

    context 'with Postgres 9.3' do
      let(:postgres_version) { 90_300 }

      it { is_expected.to be true }
    end

    context 'with Postgres 9.0' do
      let(:postgres_version) { 90_000 }

      it { is_expected.to be false }
    end
  end

  describe '.columns' do
    subject { adapter.columns(table).find { |column| column.name == 'test' } }

    context 'with temporal tables' do
      include_context 'with temporal tables'

      it { is_expected.to have_attributes(default: 'default-value', null: false) }
    end

    context 'with plain tables' do
      include_context 'with plain tables'

      it { is_expected.to have_attributes(default: 'default-value', null: false) }
    end
  end

  describe '.primary_key' do
    subject { adapter.primary_key(table) }

    context 'with temporal tables' do
      include_context 'with temporal tables'

      it { is_expected.to eq 'id' }
    end

    context 'with plain tables' do
      include_context 'with plain tables'

      it { is_expected.to eq 'id' }
    end
  end

  describe 'reading many tables at once', if: ActiveRecord::VERSION::STRING >= '8.2' do
    include_context 'with temporal tables'

    before do
      adapter.create_table 'plain_table', &columns
      adapter.add_index 'plain_table', :foo
      adapter.on_temporal_schema { adapter.add_index table, :foo }
    end

    after { adapter.drop_table 'plain_table' }

    let(:tables) { ['plain_table', table] }

    it 'reads temporal tables in the temporal schema, in the requested order' do
      defaults = adapter.columns(tables).transform_values { |cols| cols.to_h { |c| [c.name, c.default] } }

      expect(defaults.keys).to eq tables
      expect(defaults[table]).to eq(defaults['plain_table']).and include('test' => 'default-value')
    end

    it { expect(adapter.primary_keys(tables)).to eq('plain_table' => ['id'], table => ['id']) }

    it {
      expect(adapter.indexes(tables).transform_values { |indexes| indexes.map(&:name) })
        .to eq('plain_table' => ['index_plain_table_on_foo'], table => ['index_test_table_on_foo'])
    }

    it { expect(adapter.columns([])).to eq({}) }
  end

  describe '.on_schema' do
    subject(:on_schema) { adapter }

    before do
      adapter.execute 'BEGIN'
      5.times { |i| adapter.execute "CREATE SCHEMA test_#{i}" }
    end

    after do
      adapter.execute 'ROLLBACK'
    end

    context 'with default settings' do
      it 'saves the schema at each recursion' do
        expect(on_schema).to be_in_schema(:default)

        adapter.on_schema('test_1') do
          expect(on_schema).to be_in_schema('test_1')
          adapter.on_schema('test_2') do
            expect(on_schema).to be_in_schema('test_2')
            adapter.on_schema('test_3') do
              expect(on_schema).to be_in_schema('test_3')
            end
            expect(on_schema).to be_in_schema('test_2')
          end
          expect(on_schema).to be_in_schema('test_1')
        end

        expect(on_schema).to be_in_schema(:default)
      end

      context 'when errors occur' do
        subject(:on_schema) do
          adapter.on_schema('test_1') do
            adapter.on_schema('test_2') do
              adapter.execute 'ERRORING ON PURPOSE'
            end
          end
        end

        it {
          expect { on_schema }
            .to raise_error(ActiveRecord::StatementInvalid, /syntax error/)
            .and(change { adapter.instance_variable_get(:@schema_search_path) }.to(nil))
        }

        it 'restores the search path after rollback' do
          expect { on_schema }.to raise_error(ActiveRecord::StatementInvalid)

          adapter.execute 'ROLLBACK'

          expect(adapter.schema_search_path).to eq '"$user", public'
          expect(adapter).to be_in_schema(:default)
        end
      end
    end

    context 'with recurse: :ignore' do
      it 'ignores recursive calls' do
        expect(on_schema).to be_in_schema(:default)

        adapter.on_schema('test_1', recurse: :ignore) do
          expect(on_schema).to be_in_schema('test_1')
          adapter.on_schema('test_2',
                            recurse: :ignore) do
            expect(on_schema).to be_in_schema('test_1')
            adapter.on_schema('test_3',
                              recurse: :ignore) do
              expect(on_schema).to be_in_schema('test_1')
            end
          end
        end

        expect(on_schema).to be_in_schema(:default)
      end
    end
  end

  describe '.is_chrono?' do
    subject(:is_chrono?) { adapter.is_chrono?(table) }

    context 'with temporal tables' do
      include_context 'with temporal tables'

      it { is_expected.to be true }
    end

    context 'with plain tables' do
      include_context 'with plain tables'

      it { is_expected.to be false }
    end

    context 'when schemas are not there yet' do
      before do
        adapter.execute 'BEGIN'
        adapter.execute 'DROP SCHEMA temporal CASCADE'
        adapter.execute 'DROP SCHEMA history CASCADE'
        adapter.execute 'CREATE TABLE test_table (id integer)'
      end

      after do
        adapter.execute 'ROLLBACK'
      end

      it 'does not raise errors' do
        expect do
          is_chrono?
        end.not_to raise_error
      end

      it { is_expected.to be false }
    end
  end
end
