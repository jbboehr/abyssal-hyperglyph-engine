--TEST--
Abyssal Hyperglyph Engine loads as a Zend extension
--FILE--
<?php

$name = 'Abyssal Hyperglyph Engine: Gate of the Adamantine Oath';

var_dump(in_array($name, get_loaded_extensions(true), true));
?>
--EXPECT--
bool(true)
