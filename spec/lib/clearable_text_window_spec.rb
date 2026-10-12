# frozen_string_literal: true

# Tests the layout `clearable` attribute of text windows: with it, a
# <clearStream> for one of the window's streams empties the window, so the
# game can redraw it whole (a live panel); without it the window keeps its
# lines as before. Driven through the real server loop
# (GameTextProcessor#run) onto the virtual screen.

require_relative '../spec_helper'
require 'rexml/document'
require_relative '../../lib/game_text_processor'
require_relative '../../lib/shared_state'
require_relative '../../lib/window_manager'

RSpec.describe 'A clearable text window' do
  let(:event_bus) { EventBus.new }
  let(:wm) { WindowManager.new }
  let(:state) { SharedState.new.tap { |s| s.skip_server_time_offset = true } }
  let(:processor) do
    GameTextProcessor.new(
      window_mgr: wm,
      shared_state: state,
      cmd_buffer: Struct.new(:window).new(nil),
      xml_escapes: { '&lt;' => '<', '&gt;' => '>', '&quot;' => '"', '&apos;' => "'", '&amp;' => '&' },
      event_bus: event_bus
    )
  end
  let(:errors) { [] }

  before do
    GagPatterns.load_defaults
    allow(ProfanityLog).to receive(:write) { |context, message, **| errors << "#{context}: #{message}" }
  end

  def load(assess_attrs = " clearable='true'")
    LAYOUT['clearable'] = REXML::Document.new(<<~XML).root
      <layout>
        <window class='text' top='0' left='0' height='4' width='30' value='main'/>
        <window class='text' top='4' left='0' height='4' width='30' value='assess'#{assess_attrs}/>
        <window class='text' top='8' left='0' height='4' width='30' value='combat'/>
      </layout>
    XML
    wm.load_layout('clearable')
    wm.subscribe_to_events(event_bus)
  end

  # Feed raw server lines through GameTextProcessor#run, as the socket would.
  def receive_from_server(*lines)
    queue = lines.map { |line| "#{line}\r\n" }
    server = Object.new
    server.define_singleton_method(:gets) { queue.shift&.dup }
    allow(IO).to receive(:select).and_return(nil)
    allow(processor).to receive(:show_disconnect_message)
    allow(processor).to receive(:exit)
    processor.run(server)
  end

  # A redraw of the panel, as the game sends one.
  def panel(*lines)
    lines = lines.dup
    lines[0] = "<clearStream id='assess'/><pushStream id='assess'/>#{lines[0]}"
    lines[-1] = "#{lines[-1]}<popStream/>"
    lines
  end

  let(:assess) { wm.stream['assess'] }

  it 'shows only the latest redraw, from its top row' do
    load
    receive_from_server(*panel('> Vinnie  near', 'Sal  close'))
    receive_from_server(*panel('> Vinnie  far'))

    expect(assess.rows).to eq ['> Vinnie  far', '', '', '']
    expect(errors).to be_empty
  end

  it 'leaves the other windows alone' do
    load
    receive_from_server('You wave.', "<pushStream id='combat'/>Bang.<popStream/>")
    receive_from_server(*panel('> Vinnie  near'))

    expect(wm.stream['main'].rows).to include 'You wave.'
    expect(wm.stream['combat'].rows).to include 'Bang.'
  end

  it 'keeps the window when another stream is cleared' do
    load
    receive_from_server(*panel('> Vinnie  near'))
    receive_from_server("<clearStream id='combat'/>")

    expect(assess.rows).to include '> Vinnie  near'
  end

  it "keeps its lines without clearable, as before (and with clearable='false')" do
    [nil, " clearable='false'"].each do |attrs|
      load(attrs.to_s)
      receive_from_server(*panel('first'))
      receive_from_server(*panel('second'))

      expect(assess.rows).to include('first', 'second')
    end
  end

  it 'clears a window that lists the stream among others' do
    LAYOUT['shared'] = REXML::Document.new(<<~XML).root
      <layout><window class='text' top='0' left='0' height='4' width='30' value='main,assess' clearable='true'/></layout>
    XML
    wm.load_layout('shared')
    wm.subscribe_to_events(event_bus)
    receive_from_server('You wave.')
    receive_from_server(*panel('> Vinnie  near'))

    expect(wm.stream['main'].rows).to eq ['> Vinnie  near', '', '', '']
  end
end
