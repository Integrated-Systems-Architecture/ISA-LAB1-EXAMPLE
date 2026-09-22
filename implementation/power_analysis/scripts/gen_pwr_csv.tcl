# Copyright 2023 EPFL, Politecnico di Torino, and Università di Bologna.
# Solderpad Hardware License, Version 2.1, see LICENSE.md for details.
# SPDX-License-Identifier: Apache-2.0 WITH SHL-2.1
#
# File: gen_pwr_csv.tcl
# Author: University of Bologna, Michele Caon
# Date: 02/11/2023
# Description: Generate a CSV with cell power consumption

# This script is adapted from the one provided by the University of Bologna

proc gen_pwr_csv { fp cell_name } {
    # Reset global power metrics
    set INT_GLOB    0.0
    set SW_GLOB     0.0
    set LEAK_GLOB   0.0
    set TOT_GLOB    0.0

    # Initialize cell metric lists
    set INT_LIST    {}
    set SW_LIST     {}
    set LEAK_LIST   {}
    set TOT_LIST    {}

    # Get a list of cells
    set CELL_LIST [get_cells *]

    # Loop over all cells
    foreach_in_collection item $CELL_LIST {
        # Get cell power metrics
        set INT_CELL    [get_attribute $item internal_power ]
        set SW_CELL     [get_attribute $item switching_power]
        set LEAK_CELL   [get_attribute $item leakage_power  ]
        set TOT_CELL    [get_attribute $item total_power    ]

        # Update global power metrics
        if {$INT_CELL != ""} {
            set INT_GLOB  [expr $INT_GLOB  + $INT_CELL ]
        }
        if {$SW_CELL != ""} {
            set SW_GLOB   [expr $SW_GLOB   + $SW_CELL  ]
        }
        if {$LEAK_CELL != ""} {
            set LEAK_GLOB [expr $LEAK_GLOB + $LEAK_CELL]
        }
        if {$TOT_CELL != ""} {
            set TOT_GLOB  [expr $TOT_GLOB  + $TOT_CELL ]
        }
    }

    # Write global power metrics to file
    puts $fp "$cell_name,$INT_GLOB,$SW_GLOB,$LEAK_GLOB,$TOT_GLOB,1.0"

    # Write cell power metrics to file
    set IDX 0
    foreach_in_collection item $CELL_LIST {
        set CELL_NAME [get_object_name $item]

        # Get cell power metrics
        set INT_CELL    [get_attribute $item internal_power ]
        set SW_CELL     [get_attribute $item switching_power]
        set LEAK_CELL   [get_attribute $item leakage_power  ]
        set TOT_CELL    [get_attribute $item total_power    ]

        if {$TOT_CELL == ""} {
            set REL_CELL 0.0
        } else {
            set REL_CELL    [expr $TOT_CELL / $TOT_GLOB]
        }

        puts $fp "$CELL_NAME,$INT_CELL,$SW_CELL,$LEAK_CELL,$TOT_CELL,$REL_CELL"
        
        set IDX [expr $IDX + 1]
    }
}