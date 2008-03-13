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

    # To handle has_many :through, lets process the through_reflection and then send over the conditions...
    conditions.blank? or subquery_sql =
      if association.options[:through]
        through_association = reflect_on_association(association.through_reflection.name)
        source_association ||= through_association.klass.reflect_on_association(association.options[:source])
        source_association ||= through_association.klass.reflect_on_association(association.name)
        source_association ||= through_association.klass.reflect_on_association(association.name.to_s.singularize.to_sym)

        raise "Unknown source_association for HasManyThroughAssociation #{self}##{association.name}." unless source_association

        through_association.klass.__send__(:construct_find_by_association_conditions_subquery_sql,
          through_association, { source_association.name => conditions }, :through_type => name)
      else
        construct_find_by_association_conditions_subquery_sql(association, conditions, :type => association_type)
      end
    
    segments = []

    subquery_sql and segments <<
      case association.macro
      when :belongs_to
        "#{table_name}.#{connection.quote_column_name(association.primary_key_name)} IN (#{subquery_sql})"
      when :has_and_belongs_to_many
        "#{table_name}.#{connection.quote_column_name(primary_key)} IN (SELECT #{connection.quote_column_name(association.primary_key_name)} FROM #{association.options[:join_table]} WHERE #{connection.quote_column_name(association.association_foreign_key)} IN (#{subquery_sql}))"
      when :has_one
        "#{table_name}.#{connection.quote_column_name(primary_key)} IN (#{subquery_sql})"
      when :has_many
        "#{table_name}.#{connection.quote_column_name(primary_key)} IN (#{subquery_sql})"
      else raise "Unrecognized Association Macro '#{association.macro}' not supported by FindByAssociation."
      end

    nil_condition and segments << construct_find_by_association_conditions_nil_condition_sql(association)

    segments.join(' OR ') unless segments.empty?
  
  end
  
  def construct_find_by_association_conditions_nil_condition_sql(association)
    nil_subquery_sql = 
      if association.options[:through]
        through_association.klass.__send__(:construct_finder_sql, options_for_find_by_association_subquery(through_association, nil))
      else
        association_klass.__send__(:construct_finder_sql, options_for_find_by_association_subquery(association, nil, association_klass))
      end

    case association.macro
    when :belongs_to
      "#{table_name}.#{connection.quote_column_name(association.primary_key_name)} NOT IN (#{nil_subquery_sql}) OR " <<
        "#{table_name}.#{connection.quote_column_name(association.primary_key_name)} IS NULL"
    when :has_one
      "#{table_name}.#{connection.quote_column_name(primary_key)} NOT IN (#{nil_subquery_sql})"
    when :has_many
      "#{table_name}.#{connection.quote_column_name(primary_key)} NOT IN (#{nil_subquery_sql})"
    when :has_and_belongs_to_many
      "#{table_name}.#{connection.quote_column_name(primary_key)} NOT IN (SELECT #{connection.quote_column_name(association.primary_key_name)} FROM #{association.options[:join_table]} WHERE #{connection.quote_column_name(association.association_foreign_key)} IN (#{nil_subquery_sql}))"
    else
      # other association types are not supported for :association_name => nil type finds for now.
      raise "Find by association currently only supports find on nil for :belongs_to type associations."
    end
    
  end

  def construct_find_by_association_conditions_subquery_sql(association, conditions, options={})

    association_type, through_type = options[:type], options[:through_type]
    association = reflect_on_association(association) unless association.is_a?(ActiveRecord::Reflection::AssociationReflection)
    
    association.options[:polymorphic] and !association_type and
      raise "FindByAssociation requires a :type option for generation of polymorphic belongs_to association subqueries."
    
    association_type ||= association_type.is_a?(String) ? association_type.constantize : association.klass

    conditions =
      case conditions
      when [] : nil
      when Entrails::ActiveRecord::FindByAssociation : [conditions]
      else conditions
      end
    
    if conditions.is_a?(Array) and conditions.all?{|c|c.is_a?(Entrails::ActiveRecord::FindByAssociation)}
      ids = conditions.map{|c| c.attributes[association_type.primary_key] }
      ids = ids.first unless ids.size > 1
      conditions = { association_type.primary_key => ids }
    end

    conditions and association_type.__send__(:construct_finder_sql, options_for_find_by_association_conditions_subquery(
      association, conditions, :type => association_type, :through_type => through_type))

  end

  def options_for_find_by_association_conditions_subquery(association, conditions, options={})
    association_type, through_type = options[:type], options[:through_type]
    association = reflect_on_association(association) unless association.is_a? ActiveRecord::Reflection::AssociationReflection
    
    association.options[:polymorphic] and !association_type and
      raise "Polymorphic belongs_to associations require the :type argument for options_for_find_by_association_conditions_subquery."

    association_type ||= association_type.is_a?(String) ? association_type.constantize : association.klass

    options = {}
    options[:select] = case association.macro
                       when :belongs_to, :has_and_belongs_to_many then association_type.primary_key
                       else association.primary_key_name
                       end
    segments = []
    # segments << "#{options[:select]} IS NOT NULL"
    conditions and segments << association_type.__send__(:sanitize_sql, conditions)
    association.options[:conditions] and segments << association_type.__send__(:sanitize_sql, association.options[:conditions])
    association.options[:as] and segments << association_type.__send__(:sanitize_sql, (association_klass.reflect_on_association(association.options[:as].to_sym).options[:foreign_type] || :"#{association.options[:as]}_type").to_sym => (through_type||self.to_s))
    segments.reject! {|c|c.blank?}
    options[:conditions] = segments.size > 1 ? "(#{segments.join(') AND (')})" : segments.first unless segments.empty?
    # subqueries in MySQL can not use order or limit
    # options[:order] = association.options[:order] if association.options[:order]
    # options[:limit] = association.options[:limit] if association.options[:limit]
    options
  end
  
  def self.extended(host)
    super
    class << host
      alias_method :sanitize_sql_hash_for_conditions, :sanitize_sql_hash_with_find_by_association
      alias_method_chain :sanitize_sql_hash, :find_by_association
      alias_method_chain :with_scope, :find_by_association
    end
  end
  
end