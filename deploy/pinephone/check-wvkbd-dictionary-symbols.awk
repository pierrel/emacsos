$8 == "glide_word_bytes" || $8 == "glide_buckets" {
    sum += $3
    found++
}

END {
    exit !(found == 2 && sum <= 262144)
}
