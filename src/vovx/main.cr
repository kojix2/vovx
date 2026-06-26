require "../vovx"

{% unless flag?(:execution_context) %}
  {% raise "This project requires -Dexecution_context. Example: crystal build src/vovx/main.cr -Dpreview_mt -Dexecution_context" %}
{% end %}

VOVX.run_cli
