# Dummy up some MySQL constants.
module RSQL
    class Mysql
        class Error < Exception
        end
        class Field
            TYPE_TINY_BLOB = 1
            TYPE_STRING    = 2
        end
    end
end
