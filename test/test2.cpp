#include <string>

class ApiClientV2 {
public:
    explicit ApiClientV2(std::string base_url) : base_url_(base_url) {}

    std::string get_data(const std::string& path) {
        return base_url_ + path;
    }

private:
    std::string base_url_;
    int timeout_ms = 45;
};

const std::string API_URL = "https://api.example.com/v2";
int request_timeout = 60;
int timeout_duration = 30;
