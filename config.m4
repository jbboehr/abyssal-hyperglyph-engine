PHP_ARG_ENABLE([abyssal-hyperglyph-engine],
  [whether to enable Abyssal Hyperglyph Engine],
  [AS_HELP_STRING([--enable-abyssal-hyperglyph-engine],
    [Enable Abyssal Hyperglyph Engine: Gate of the Adamantine Oath])],
  [no])

AS_VAR_IF([PHP_ABYSSAL_HYPERGLYPH_ENGINE], [no],, [
  PHP_NEW_EXTENSION([abyssal_hyperglyph_engine],
    [src/abyssal_hyperglyph_engine.c src/ahe_broker_client.c],
    [$ext_shared],,
    [-DZEND_ENABLE_STATIC_TSRMLS_CACHE=1])
])
