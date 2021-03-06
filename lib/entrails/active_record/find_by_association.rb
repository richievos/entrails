module Entrails::ActiveRecord::FindByAssociation
  
  protected
  
  # Sanitizes a hash of association/value pairs into SQL conditions,
  # passing on attributes that are not associations back down into
  # the original sanitize_sql_hash method.
  def sanitize_sql_hash_with_find_by_association(attrs)
    attrs = attrs.dup
    association_conditions = attrs.map do |attr, value|
      # Lets process Attributes that are names of Associations
      if association = reflect_on_association(attr.to_sym)
        attrs.delete attr
        if association.options[:polymorphic]
          foreign_type_attribute = (association.options[:foreign_type]||"#{association.name}_type").to_s
          polymorphic_type = attrs[foreign_type_attribute.to_sym]
          raise "Polymorphic belongs_to associations must be qualified by the inclusion of a reference to the foreign_type attribute in the conditions hash.  Missing #{foreign_type_attribute} key or value in conditions hash passed to sanitize_sql_hash_with_find_by_association for association #{association.name}." unless polymorphic_type
          association_class = polymorphic_type.constantize
        else
          association_class = association.klass
        end
        construct_find_by_association_conditions_sql(association, value, :type => association_class)
      end
    end.compact.join(' AND ')
    non_association_conditions = attrs.empty? ? '' : sanitize_sql_hash_without_find_by_association(attrs)
  
    # Non Association Conditions are cheaper to calculate so we optimize the query plan by issuing them first
    [ non_association_conditions, association_conditions ].reject{|conditions| conditions.blank?}.join(' AND ')
  end

  # Prevent infinite recursion when assigning scopes via with_scope block
  # by sanitizing non-string scope conditions.
  def with_scope_with_find_by_association(options={}, action = :merge, &block)
    if options[:find] and options[:find][:conditions] and !options[:find][:conditions].is_a?(String)
      options = options.dup
      options[:find] = options[:find].dup
      options[:find][:conditions] = sanitize_sql(options[:find][:conditions])
    end
    with_scope_without_find_by_association options, action, &block
  end

  private
  
  def construct_find_by_association_conditions_sql(association, conditions, options={})
    
    association_type = options[:type]
    association = reflect_on_association(association) unless association.is_a?(ActiveRecord::Reflection::AssociationReflection)

    association.options[:polymorphic] and !association_type and
      raise "FindByAssociation requires a :type option for generation of polymorphic belongs_to association subqueries."  
    
    association_type ||= association.is_a?(String) ? association_type.constantize : association.klass

    # If a nil is present in the association conditions we have to handle as a special case due to the way
    # sql handles NULL values in sets vs. empty sets.
    nil_condition =
      case conditions
      when Array : !!conditions.compact! # compacts the array and returns true/false if it changed
      when NilClass : true
      else false
      end

    segments = []

    # To handle has_many :through, lets process the through_reflection and then send over the conditions...
    conditions.blank? or segments <<
      if association.options[:through]
        through_association = reflect_on_association(association.through_reflection.name)
        source_association ||= through_association.klass.reflect_on_association(association.options[:source])
        source_association ||= through_association.klass.reflect_on_association(association.name)
        source_association ||= through_association.klass.reflect_on_association(association.name.to_s.singularize.to_sym)

        raise "Unknown source_association for HasManyThroughAssociation #{self}##{association.name}." unless source_association

        source_subquery_sql = through_association.klass.__send__(:construct_find_by_association_conditions_subquery_sql,
          source_association, conditions, :type => association_type)

        through_subquery_sql = construct_find_by_association_conditions_subquery_sql(
          through_association, source_subquery_sql, :type => through_association.klass)
      else
        construct_find_by_association_conditions_subquery_sql(association, conditions, :type => association_type)
      end

    nil_condition and segments << construct_find_by_association_conditions_nil_condition_sql(association)

    segments.join(' OR ') unless segments.empty?
  
  end
  
  def construct_find_by_association_conditions_nil_condition_sql(association)
    nil_subquery_sql = 
      if association.options[:through]
        through_association = reflect_on_association(association.through_reflection.name)
        through_association.klass.__send__(:construct_finder_sql, options_for_find_by_association_conditions_subquery(through_association, nil))
      else
        association.klass.__send__(:construct_finder_sql, options_for_find_by_association_conditions_subquery(association, nil, :type => association.klass))
      end

    nil_subquery_sql = "SELECT _id FROM (#{nil_subquery_sql}) _tmp" if use_derived_table_hack_for_subquery_optimization?

    case association.macro
    when :belongs_to : "#{table_name}.#{connection.quote_column_name(association.primary_key_name)} NOT IN " <<
                       "(#{nil_subquery_sql}) OR #{table_name}.#{connection.quote_column_name(association.primary_key_name)} IS NULL"
    when :has_one    : "#{table_name}.#{connection.quote_column_name(primary_key)} NOT IN (#{nil_subquery_sql})"
    when :has_many   : "#{table_name}.#{connection.quote_column_name(primary_key)} NOT IN (#{nil_subquery_sql})"
    when :has_and_belongs_to_many : "#{table_name}.#{connection.quote_column_name(primary_key)} NOT IN " <<
                                    "(SELECT #{connection.quote_column_name(association.primary_key_name)} " <<
                                    "FROM #{association.options[:join_table]} WHERE " <<
                                    "#{connection.quote_column_name(association.association_foreign_key)} IN " <<
                                    "(#{nil_subquery_sql}))"
    else raise "FindByAssociation does not recognize the '#{association.macro}' association macro."
    end
    
  end

  def construct_find_by_association_conditions_subquery_sql(association, conditions, options={})

    association_type, through_type = options[:type], options[:through_type]
    association = reflect_on_association(association) unless association.is_a?(ActiveRecord::Reflection::AssociationReflection)
    
    association.options[:polymorphic] and !association_type and
      raise "FindByAssociation requires a :type option for generation of polymorphic belongs_to association subqueries."
    
    association_type ||= association_type.is_a?(String) ? association_type.constantize : association.klass

    conditions =
      case
      when (conditions == []) : nil
      when (conditions.class.is_a?(Entrails::ActiveRecord::FindByAssociation)) : [conditions]
      else conditions
      end
      
    if conditions.is_a?(Array) and conditions.all?{|c|c.class.is_a?(Entrails::ActiveRecord::FindByAssociation)}
      ids = conditions.map{|c| c.attributes[association_type.primary_key] }
      ids = ids.first unless ids.size > 1
      conditions = { association_type.primary_key => ids }
    end

    if conditions and subquery_sql = association_type.__send__(:construct_finder_sql, 
      options_for_find_by_association_conditions_subquery(association, conditions, :type => association_type, :through_type => through_type))

      subquery_sql &&= "SELECT _id FROM (#{subquery_sql}) _tmp" if use_derived_table_hack_for_subquery_optimization?

      case association.macro
      when :belongs_to : "#{table_name}.#{connection.quote_column_name(association.primary_key_name)} IN (#{subquery_sql})"
      when :has_and_belongs_to_many : "#{table_name}.#{connection.quote_column_name(primary_key)} IN " <<
                                      "(SELECT #{connection.quote_column_name(association.primary_key_name)} " <<
                                      "FROM #{association.options[:join_table]} WHERE " <<
                                      "#{connection.quote_column_name(association.association_foreign_key)} IN " <<
                                      "(#{subquery_sql}))"
      when :has_one  : "#{table_name}.#{connection.quote_column_name(primary_key)} IN (#{subquery_sql})"
      when :has_many : "#{table_name}.#{connection.quote_column_name(primary_key)} IN (#{subquery_sql})"
      else raise "Unrecognized Association Macro '#{association.macro}' not supported by FindByAssociation."
      end

    end
  end
  
  # Update the dynamic finders to allow referencing association names instead of
  # just column names.
  def method_missing_with_find_by_association(method_id, *arguments)
    match = /^find_(all_by|by)_([_a-zA-Z]\w*)$/.match(method_id.to_s)
    match = /^find_or_(initialize|create)_by_([_a-zA-Z]\w*)$/.match(method_id.to_s) unless match
    if match
      action_type_segment = $1
      attribute_names_segment = $2
      action_type = (action_type_segment =~ /by/) ? :finder : :instantiator
      attribute_names = attribute_names_segment.split(/_and_/)
      options_argument = (arguments.size > attribute_names.size) ? arguments.last : {}
      associations = {}
      index = 0

      non_associations = attribute_names.select do |attribute_name|
        attribute_chain = attribute_name.split('_having_')
        attribute_name = attribute_chain.shift
        if reflect_on_association(attribute_name.to_sym)
          associations[attribute_name.to_sym] ||= attribute_chain.reverse.inject(arguments.delete_at(index)){|v,n|{n=>v}}
          false
        else
          index += 1
          true
        end
      end

      unless associations.empty?
        find_options = { :conditions => associations }
        set_readonly_option!(find_options)
        with_scope :find => find_options do
          if action_type == :finder
            finder = match.captures.first == 'all_by' ? :find_every : :find_initial
            return __send__(finder, options_argument) if non_associations.empty?
            return __send__("find#{'_all' if finder == :find_every}_by_#{non_associations.join('_and_')}".to_sym, *arguments)
          else
            instantiator = determine_instantiator(match)
            return find_initial(options_argument) || __send__(instantiator, associations) if non_associations.empty?
            return __send__("find_or_#{instantiator}_by_#{non_associations.join('_and_')}".to_sym, *arguments) 
          end
        end
      end
    end

    method_missing_without_find_by_association method_id, *arguments

  end

  def options_for_find_by_association_conditions_subquery(association, conditions, options={})

    association_type, through_type = options[:type], options[:through_type]
    association = reflect_on_association(association) unless association.is_a? ActiveRecord::Reflection::AssociationReflection
    
    association.options[:polymorphic] and !association_type and
      raise "Polymorphic belongs_to associations require the :type argument for options_for_find_by_association_conditions_subquery."

    association_type ||= association_type.is_a?(String) ? association_type.constantize : association.klass

    options = {}
    
    key_column = case association.macro
                 when :belongs_to,
                      :has_and_belongs_to_many : association_type.primary_key
                 else association.primary_key_name
                 end

    options[:select] = "#{key_column} _id"
    segments = []
    segments << "#{key_column} IS NOT NULL"
    conditions and segments << association_type.__send__(:sanitize_sql, conditions)
    association.options[:conditions] and segments << association_type.__send__(:sanitize_sql, association.options[:conditions])
    association.options[:as] and segments << association_type.__send__(:sanitize_sql, (association_type.reflect_on_association(association.options[:as].to_sym).options[:foreign_type] || :"#{association.options[:as]}_type").to_sym => (through_type||self).name)
    segments.reject! {|c|c.blank?}
    options[:conditions] = segments.size > 1 ? "(#{segments.join(') AND (')})" : segments.first unless segments.empty?

    # subqueries in MySQL can not use order or limit
    # options[:order] = association.options[:order] if association.options[:order]
    # options[:limit] = association.options[:limit] if association.options[:limit]

    options

  end
  
  # This is an affordance to turn on/off the use of a wrapper query that generates
  # an aliased derived table for the purpose of query-plan optimization for some
  # database engines.  This hack has been shown to significantly benefit query times
  # for mysql and sqlite3. (has not yet been tested with other engines.)
  def use_derived_table_hack_for_subquery_optimization?
    false
  end
  
  def self.extended(host)
    super
    class << host
      alias_method :sanitize_sql_hash_for_conditions, :sanitize_sql_hash_with_find_by_association
      alias_method_chain :method_missing, :find_by_association
      alias_method_chain :sanitize_sql_hash, :find_by_association
      alias_method_chain :with_scope, :find_by_association
    end
  end
  
end
