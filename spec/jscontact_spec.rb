# frozen_string_literal: true

require "open3"

RSpec.describe Jscontact do
  it "loads the JSON API without loading the optional vCard dependency" do
    output, status = Open3.capture2(RbConfig.ruby, "-Ilib", "-rjscontact", "-e", <<~RUBY)
      abort "unexpected vCard dependency" if $LOADED_FEATURES.any? { |file| file.include?("/jcard_jcal") }
      card = JSContact::Card.build do |contact|
        contact.name = { full: "Mina Sample" }
        contact.add_email(address: "mina@example.test", contexts: { work: true })
      end
      abort "round trip changed the Card" unless JSContact.parse(card.to_json) == card
      puts card.name.full
    RUBY
    expect(status).to be_success
    expect(output).to eq("Mina Sample\n")
  end
end
