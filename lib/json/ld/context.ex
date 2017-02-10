defmodule JSON.LD.Context do
  defstruct term_defs: %{},
            vocab: nil,
            base_iri: nil,
            default_language: nil

  import JSON.LD

  alias JSON.LD.Context.TermDefinition

  @keywords JSON.LD.keywords # to allow this to be used in function guard clauses, we redefine this here


  def new(opts \\ [])

  def new([base: base_iri]), do: %JSON.LD.Context{base_iri: base_iri}
  def new(_), do: %JSON.LD.Context{}


  def create(%{"@context" => json_ld_context}, opts),
    do: new(opts) |> update(json_ld_context, Keyword.get(opts, :remote, []))


  def update(active, local, remote \\ [])

  def update(%JSON.LD.Context{} = active, local, remote) when is_list(local) do
    Enum.reduce local, active, fn (local, result) ->
      do_update(result, local, remote)
    end
  end

  # 2) If local context is not an array, set it to an array containing only local context.
  def update(%JSON.LD.Context{} = active, local, remote) do
    update(active, [local], remote)
  end

  # 3.1) If context is null, set result to a newly-initialized active context and continue with the next context. The base IRI of the active context is set to the IRI of the currently being processed document (which might be different from the currently being processed context), if available; otherwise to null. If set, the base option of a JSON-LD API Implementation overrides the base IRI.
  defp do_update(%JSON.LD.Context{} = active, nil, remote) do
    # TODO: "If set, the base option of a JSON-LD API Implementation overrides the base IRI."
    JSON.LD.Context.new(base: active.base_iri)
  end

  # 3.2) If context is a string, [it's interpreted as a remote context]
  defp do_update(%JSON.LD.Context{} = active, local, remote) when is_binary(local) do
    # TODO: fetch remote context and call recursively with remote updated
  end

  # 3.4) - 3.8)
  defp do_update(%JSON.LD.Context{} = active, local, remote) when is_map(local) do
    with {base, local}     <- Map.pop(local, "@base", :undefined),
         {vocab, local}    <- Map.pop(local, "@vocab", :undefined),
         {language, local} <- Map.pop(local, "@language", :undefined) do
      active
      |> set_base(base, remote)
      |> set_vocab(vocab)
      |> set_language(language)
      |> create_term_definitions(local)
    end
  end

  # 3.3) If context is not a JSON object, an invalid local context error has been detected and processing is aborted.
  defp do_update(_, local, _),
    do: raise JSON.LD.InvalidLocalContextError,
          message: "#{inspect local} is not a valid @context value"


  defp set_base(active, :undefined, _),
    do: active
  defp set_base(active, _, remote) when is_list(remote) and length(remote) > 0,
    do: active
  defp set_base(active, base, _) do
    cond do
      is_nil(base) or absolute_iri?(base) ->
        %JSON.LD.Context{active | base_iri: base}
      not is_nil(active.base_iri) ->
        %JSON.LD.Context{active | base_iri: absolute_iri(base, active.base_iri)}
      true ->
        raise JSON.LD.InvalidBaseURIError,
          message: "#{inspect base} is a relative IRI, but no active base IRI defined"
    end
  end

  defp set_vocab(active, :undefined), do: active
  defp set_vocab(active, vocab) do
    if is_nil(vocab) or absolute_iri?(vocab) or blank_node_id?(vocab) do
      %JSON.LD.Context{active | vocab: vocab}
    else
      raise JSON.LD.InvalidVocabMappingError,
        message: "#{inspect vocab} is not a valid vocabulary mapping"
    end
  end

  defp set_language(active, :undefined), do: active
  defp set_language(active, nil),
    do: %JSON.LD.Context{active | default_language: nil}
  defp set_language(active, language) when is_binary(language),
    do: %JSON.LD.Context{active | default_language: String.downcase(language)}
  defp set_language(_, language),
    do: raise JSON.LD.InvalidDefaultLanguageError,
          message: "#{inspect language} is not a valid language"

  defp create_term_definitions(active, local, defined \\ %{}) do
    {active, _} =
      Enum.reduce local, {active, defined}, fn ({term, value}, {active, defined}) ->
        create_term_definition(active, local, term, value, defined)
      end
    active
  end

  @doc """
  Expands the given input according to the steps in the JSON-LD Create Term Definition Algorithm.

  see https://www.w3.org/TR/json-ld-api/#create-term-definition
  """
  def create_term_definition(active, local, term, value, defined)

  def create_term_definition(active, _, "@base", _, defined),     do: {active, defined}
  def create_term_definition(active, _, "@vocab", _, defined),    do: {active, defined}
  def create_term_definition(active, _, "@language", _, defined), do: {active, defined}

  def create_term_definition(active, local, term, value, defined) do
    # 3)
    if term in JSON.LD.keywords,
      do: raise JSON.LD.KeywordRedefinitionError,
            message: "#{inspect term} is a keyword and can not be defined in context"
    # 1)
    case defined[term] do
      true  -> {active, defined}
      false -> raise JSON.LD.CyclicIRIMappingError #, message: "#{inspect term} .."
      nil   -> do_create_term_definition(active, local, term, value,
                                          Map.put(defined, term, false)) # 2)
    end
  end

  defp do_create_term_definition(active, _local, term, nil, defined) do
    {
#      (if Map.has_key?(active.term_defs, term),
#        do: put_in(active, [:term_defs, term], nil),
#        else: raise "NotImplemented"),
      %JSON.LD.Context{active | term_defs: Map.put(active.term_defs, term, nil)},
      Map.put(defined, term, true)}
  end

  defp do_create_term_definition(active, local, term, %{"@id" => nil}, defined),
    do: do_create_term_definition(active, local, term, nil, defined)

  defp do_create_term_definition(active, local, term, value, defined) when is_binary(value),
    do: do_create_term_definition(active, local, term, %{"@id" => value}, defined)

  defp do_create_term_definition(active, local, term, %{} = value, defined) do
    definition = %TermDefinition{}  # 9)
    {definition, active, defined} =
      do_create_type_definition(definition, active, local, value, defined)
    {done, definition, active, defined} =
        do_create_reverse_definition(definition, active, local, value, defined)
    unless done do
      {definition, active, defined} =
        do_create_id_definition(definition, active, local, term, value, defined)
      definition = do_create_container_definition(definition, value)
      definition = do_create_language_definition(definition, value)
    end
    # 18 / 11.6) Set the term definition of term in active context to definition and set the value associated with defined's key term to true.
    {%JSON.LD.Context{active | term_defs: Map.put(active.term_defs, term, definition)},
      Map.put(defined, term, true)}
  end

  defp do_create_term_definition(_, _, _, value, _),
    do: raise JSON.LD.InvalidTermDefinitionError,
          message: "#{inspect value} is not a valid term definition"


  # 10.1)
  # TODO: RDF.rb implementation says: "SPEC FIXME: @type may be nil"
  defp do_create_type_definition(_, _, _, %{"@type" => type}, _) when not is_binary(type),
    do: raise JSON.LD.InvalidTypeMappingError,
                message: "#{inspect type} is not a valid type mapping"

  # 10.2) and 10.3)
  defp do_create_type_definition(definition, active, local, %{"@type" => type}, defined) do
    {expanded_type, active, defined} =
      expand_iri(type, active, false, true, local, defined)
    if absolute_iri?(expanded_type) or expanded_type in ~w[@id @vocab] do
      {%TermDefinition{definition | type_mapping: expanded_type}, active, defined}
    else
      raise JSON.LD.InvalidTypeMappingError,
              message: "#{inspect type} is not a valid type mapping"
    end
  end

  defp do_create_type_definition(definition, active, _, _, defined),
    do: {definition, active, defined}

  # 11) If value contains the key @reverse
  defp do_create_reverse_definition(definition, active, local,
                                    %{"@reverse" => reverse} = value, defined) do
    cond do
      Map.has_key?(value, "@id") ->         # 11.1)
        raise JSON.LD.InvalidReversePropertyError,
                message: "#{inspect reverse} is not a valid reverse property"
      not is_binary(reverse) ->             # 11.2)
        raise JSON.LD.InvalidIRIMappingError,
                message: "#{inspect reverse} is not a valid IRI mapping"
      true ->                               # 11.3)
        {expanded_reverse, active, defined} =
          expand_iri(reverse, active, false, true, local, defined)
        if absolute_iri?(expanded_reverse) or blank_node_id?(expanded_reverse) do
          definition = %TermDefinition{definition | iri_mapping: expanded_reverse}
        else
          raise JSON.LD.InvalidIRIMappingError,
                  message: "#{inspect reverse} is not a valid IRI mapping"
        end
        case Map.get(value, "@container", {:undefined}) do  # 11.4)
          {:undefined} -> nil
          container when is_nil(container) or container in ~w[@set @index] ->
            definition = %TermDefinition{definition | container_mapping: container}
          _ ->
            raise JSON.LD.InvalidReversePropertyError,
              message: "#{inspect reverse} is not a valid reverse property; reverse properties only support set- and index-containers"
        end
        # 11.5) & 11.6)
        {true, %TermDefinition{definition | reverse_property: true}, active, defined}
    end
  end

  defp do_create_reverse_definition(definition, active, _, _, defined),
    do: {false, definition, active, defined}


  # 13)
  defp do_create_id_definition(definition, active, local, term,
        %{"@id" => id}, defined) when id != term do
    if is_binary(id) do
      # 13.2)
      {expanded_id, active, defined} =
        expand_iri(id, active, false, true, local, defined)
      cond do
        expanded_id == "@context" ->
          raise JSON.LD.InvalidKeywordAliasError,
                  message: "#{inspect id} is an invalid keyword alias"
        keyword?(expanded_id) or
        absolute_iri?(expanded_id) or
        blank_node_id?(expanded_id) ->
          {%TermDefinition{definition | iri_mapping: expanded_id}, active, defined}
        true ->
          raise JSON.LD.InvalidIRIMappingError,
                  message: "#{inspect id} is not a valid IRI mapping"
      end
    else  # 13.1)
      raise JSON.LD.InvalidIRIMappingError,
              message: "#{inspect id} is not a valid IRI mapping"
    end
  end

  defp do_create_id_definition(definition, active, local, term, _, defined) do
    # 14)
    # TODO: The W3C spec seems to contain an error by requiring only to check for a collon.
    #  What's when an absolute IRI is given and an "http" term is defined in the context?
    if String.contains?(term, ":") do
      case compact_iri_parts(term) do
        [prefix, suffix] ->
          if prefix_mapping = local[prefix] do
            {active, defined} = do_create_term_definition(active, local, prefix, prefix_mapping, defined)
          end
          if prefix_def = active.term_defs[prefix] do
            {%TermDefinition{definition | iri_mapping: prefix_def.iri_mapping <> suffix}, active, defined}
          else
            {%TermDefinition{definition | iri_mapping: term}, active, defined}
          end
        nil -> {%TermDefinition{definition | iri_mapping: term}, active, defined}
      end
    # 15)
    else
      if active.vocab do
        {%TermDefinition{definition | iri_mapping: active.vocab <> term}, active, defined}
      else
        raise JSON.LD.InvalidIRIMappingError,
                message: "#{inspect term} is not a valid IRI mapping"
      end
    end
  end


  # 16.1)
  defp do_create_container_definition(_, %{"@container" => container})
        when not container in ~w[@list @set @index @language],
    do: raise JSON.LD.InvalidContainerMappingError,
          message: "#{inspect container} is not a valid container mapping; only @list, @set, @index, or @language allowed"
  # 16.2)
  defp do_create_container_definition(definition, %{"@container" => container}),
    do: %TermDefinition{definition | container_mapping: container}
  defp do_create_container_definition(definition, _),
    do: definition


  # 17)
  defp do_create_language_definition(definition, %{"@language" => language} = value) do
    unless Map.has_key?(value, "@type") do
      case language do
        language when is_binary(language) ->
          %TermDefinition{definition | language_mapping: String.downcase(language)}
        language when is_nil(language) ->
          %TermDefinition{definition | language_mapping: nil}
        _ ->
          raise JSON.LD.InvalidLanguageMappingError,
                  message: "#{inspect language} is not a valid language mapping"
      end
    end
  end
  defp do_create_language_definition(definition, _), do: definition

end