#include <string>

class ApiClient {
public:
    explicit ApiClient(std::string base_url) : base_url_(base_url) {}

    std::string fetch_data(const std::string& path) {
        return base_url_ + path;
    }

private:
    std::string base_url_;
    int timeout = 30;
};

const std::string API_URL = "https://api.example.com/v1";
int legacy_timeout = 30;
int timeout = 30;
