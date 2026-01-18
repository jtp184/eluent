# frozen_string_literal: true

RSpec.describe Eluent do
  it 'has a version number' do
    expect(Eluent::VERSION).not_to be_nil
  end

  it 'provides the Models module' do
    expect(Eluent::Models).to be_a(Module)
  end

  it 'provides the Storage module' do
    expect(Eluent::Storage).to be_a(Module)
  end

  it 'provides the Registry module' do
    expect(Eluent::Registry).to be_a(Module)
  end
end
