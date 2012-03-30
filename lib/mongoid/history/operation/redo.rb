module Mongoid::History::Operation
  class Redo < Abstract
    extend StateMachine::MacroMethods

    state_machine :state, :initial => :pending do
      event :prepare do
        transition :pending => :persisted,    :if     => :doc_persisted?
        transition :pending => :unpersisted,  :unless => :doc_persisted?
      end

      event :create do
        transition :unpersisted => :persisted
      end

      event :update do
        transition :persisted => :persisted
      end

      event :destroy do
        transition :persisted => :unpersisted
      end

      after_transition :on => [:create, :update], :do => :build_attributes
      after_transition :on => :destroy, :do => :clear_attributes
    end

    def execute!(modifier, tracks)
      @tracks     = tracks
      @modifer    = modifier
      @attributes = {}

      prepare!
      run!
      commit!

      @doc
    end

    def current_action
      (@current_track.action || 'update').to_sym
    end

    def doc_persisted?
      doc && doc.persisted?
    end

    def build_attributes
      builder = Mongoid::History::Builder::RedoAttributes.new(doc)
      @attributes.merge! builder.build(@current_track)
    end

    def clear_attributes
      @attributes = nil
    end

    def assign_modifier
      @attributes[meta.modifier_field] = @modifier
    end

    def run!
      until @tracks.empty?
        @current_track = @tracks.shift
        begin
          send "#{current_action}!"
        rescue StateMachine::InvalidTransition
          raise Mongoid::History::InvalidOperation
        end
      end
      assign_modifier
    end

    def commit!
      case current_action
      when :create
        re_create!
      when :destroy
        re_destroy!
      else
        update_attributes!
      end
    end

    def re_create!
      @doc =  if current_track.association_chain.length > 1
                create_on_parent!
              else
                create_standalone!
              end
    end

    def create_on_parent!
      parent = current_track.association_chain.parent
      child  = current_track.association_chain.leaf

      if parent.embeds_one?(child.name)
        parent.doc.send("create_#{child.name}!", @attributes)
      elsif parent.embeds_many?(child.name)
        parent.doc.send(child.name).create!(@attributes)
      else
        raise Mongoid::History::InvalidOperation
      end
    end

    def create_standalone!
      name = current_track.association_chain.leaf.name
      model = name.constantize
      model.create!(@attributes)
    end

    def re_destroy!
      doc.destroy!
    end

    def update_attributes!
      @doc.update_attributes!(@attributes)
    end
  end
end
